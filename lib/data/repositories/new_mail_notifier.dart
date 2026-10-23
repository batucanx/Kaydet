import '../database/app_database.dart';
import '../services/notification_service.dart';
import 'notification_ledger.dart';
import 'sync_engine.dart';

/// Yeni ileti bildirimi kararlarının tek yeri.
///
/// Ön plan denetleyicisi (`SyncController`), ön plan servisi
/// (`push_task_handler.dart`) ve periyodik arka plan görevi
/// (`background_sync.dart`) aynı kuralları paylaşır: kimin bildirileceği,
/// kaç bildirim gösterileceği ve okunan/silinen iletilerin bildirimlerinin
/// nasıl kaldırılacağı. Eskiden bu mantık iki yerde kopyalıydı.
class NewMailNotifier {
  NewMailNotifier({
    required AppDatabase database,
    required NotificationService notifications,
    this.remotePushShowsAlerts = false,
    NotificationLedger? ledger,
    Future<bool> Function(int accountId)? serverCoversAccount,
  }) : _db = database,
       _notifications = notifications,
       _ledger = ledger,
       _serverCovers = serverCoversAccount;

  final AppDatabase _db;
  final NotificationService _notifications;

  /// Bildirilen iletilerin kalıcı defteri (bkz. [NotificationLedger]). Verilmezse
  /// yalnızca eşitlemenin döndürdüğü "yeni ileti" listesine bakılır.
  final NotificationLedger? _ledger;

  /// [remotePushShowsAlerts] açıkken sunucunun BELİRLİ bir hesabı gerçekten
  /// izleyip izlemediği (bkz. `ServerPushCoverage`). İzlemiyorsa o hesabın
  /// APNs push'u hiç gelmez; yerel bildirim bastırılmaz. Verilmezse sunucu her
  /// hesabı izliyor varsayılır.
  final Future<bool> Function(int accountId)? _serverCovers;

  /// iOS'ta sunucu tabanlı push (APNs) yeni ileti bildirimini zaten kendisi
  /// gösterir. Uygulama açılıp eşitleyince aynı ileti "yeni" görünür; yerel
  /// bildirim de üretilirse kullanıcı aynı bildirimi ikinci kez alır.
  final bool remotePushShowsAlerts;

  /// Tek turda gösterilen en fazla ileti bildirimi; fazlası özet bildirimde
  /// sayı olarak görünür.
  static const int maxPerRound = 5;

  /// Bundan eski iletiler "yeni" sayılmaz ve bildirim üretmez.
  ///
  /// `SyncOutcome.initialDownload` yeni hesabın ilk indirmesini eler, ama
  /// arayüz ile ön plan servisi aynı hesabı aynı anda ilk kez eşitlerken biri
  /// diğerinin yarım bıraktığı indirmeyi "yeni ileti" diye görebilir. Gerçekten
  /// yeni bir ileti dakikalar içinde gelir; günler öncesine ait olan geçmiştir.
  static const Duration maxAge = Duration(days: 2);

  /// Bir eşitlemede gelen yeni iletileri bildirir.
  ///
  /// Bildirilecekler iki kaynağın birleşimidir: bu turun [outcome]'u VE hesabın
  /// defterinde (bkz. [NotificationLedger]) "bildirilmemiş" görünen iletiler.
  /// İkincisi, iletiyi başka bir yolun (ör. bildirim üretmeyen bir eşitleme ya da
  /// bildirim gösterilmeden durdurulan bir işçi) çekip bıraktığı durumu telafi
  /// eder: o ileti artık hiçbir turun "yeni" listesinde çıkmaz.
  ///
  /// [suppressMailboxId] doluysa ve ileti o klasöre aitse bildirim atlanır —
  /// kullanıcı o an tam da o klasörün listesine bakıyor, ileti zaten canlı
  /// olarak listede görünür.
  Future<void> notifyNew({
    required int accountId,
    required SyncOutcome outcome,
    int? suppressMailboxId,
  }) async {
    if (remotePushShowsAlerts &&
        (_serverCovers == null || await _serverCovers(accountId))) {
      return;
    }
    final ledger = _ledger;
    if (outcome.initialDownload || outcome.resynced) {
      // Yeni hesabın geçmişi bildirilmez; su çizgisi bugüne taşınır. UIDVALIDITY
      // değişip klasör baştan indirildiyse (`resynced`) eski okunmamış iletiler
      // "yeni" görünür ve zaten bildirilmiş olanlar bir kez daha bildirilirdi.
      await ledger?.advance(accountId);
      return;
    }

    final candidates = <int>{...outcome.newMessageIds};
    // Su çizgisinin gerisindeki iletiler zaten bildirilmiştir (aynı sonuç iki
    // yoldan işlenirse çift bildirim olmasın).
    final view = await ledger?.view(accountId) ?? const LedgerView();
    candidates.addAll(view.pendingIds);
    final mark = view.mark;
    if (candidates.isEmpty) {
      await ledger?.ensureInitialized(accountId);
      return;
    }

    final rows = await _db.messagesByIds(candidates.toList());
    final oldest = DateTime.now().subtract(maxAge);
    final unread = [
      for (final m in rows)
        if (!m.isSeen &&
            (mark == null || m.uid == null || m.uid! > mark) &&
            !m.isDraft &&
            !m.isDeleted &&
            m.mailboxId != suppressMailboxId &&
            m.dateUtc.isAfter(oldest))
          m,
    ];
    if (unread.isEmpty) {
      await ledger?.advance(accountId);
      return;
    }

    final account = await _db.accountById(accountId);
    final label = account?.email;

    // En yeniler gösterilir; en eskisi önce basılır ki bildirim gölgesinde
    // en yeni ileti en üstte dursun.
    unread.sort((a, b) => b.dateUtc.compareTo(a.dateUtc));
    final shown = unread.take(maxPerRound).toList().reversed;
    for (final row in shown) {
      await _notifications.showNewMail(row, accountLabel: label);
    }
    await _notifications.refreshGroupSummary(accountId, accountLabel: label);
    // Su çizgisi YALNIZCA bildirim gösterildikten sonra ilerler: bu noktadan
    // önce kesilen bir işlem iletiyi bir sonraki turda yeniden bildirir.
    await ledger?.advance(accountId);
  }

  /// Artık okunmuş, silinmiş ya da taşınmış iletilerin bildirimlerini kaldırır.
  ///
  /// Başka bir cihazdan (masaüstü, web) okunan ileti sunucuda `\Seen` olur ve
  /// eşitlemeyle buraya gelir; bildirimi gölgede bırakmak yanıltıcıdır.
  Future<void> dismissHandled() async {
    final ids = await _notifications.activeMessageIds();
    if (ids.isEmpty) return;

    final rows = await _db.messagesByIds(ids);
    final live = {
      for (final m in rows)
        if (!m.isSeen && !m.isDeleted) m.id,
    };
    final stale = [
      for (final id in ids)
        if (!live.contains(id)) id,
    ];
    if (stale.isEmpty) return;

    await _notifications.cancelMessages(stale);

    // Kaldırılan bildirimler bir grubun sayısını değiştirir; özetler
    // (2'den az çocuk kalınca özet de kaybolur) yeniden hesaplanır.
    for (final account in await _db.allAccounts()) {
      await _notifications.refreshGroupSummary(
        account.id,
        accountLabel: account.email,
      );
    }
  }
}
