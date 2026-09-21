import '../database/app_database.dart';
import '../services/notification_service.dart';
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
  }) : _db = database,
       _notifications = notifications;

  final AppDatabase _db;
  final NotificationService _notifications;

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
  /// [suppressMailboxId] doluysa ve ileti o klasöre aitse bildirim atlanır —
  /// kullanıcı o an tam da o klasörün listesine bakıyor, ileti zaten canlı
  /// olarak listede görünür.
  Future<void> notifyNew({
    required int accountId,
    required SyncOutcome outcome,
    int? suppressMailboxId,
  }) async {
    if (outcome.initialDownload || outcome.newMessageIds.isEmpty) return;

    final rows = await _db.messagesByIds(outcome.newMessageIds);
    final oldest = DateTime.now().subtract(maxAge);
    final unread = [
      for (final m in rows)
        if (!m.isSeen &&
            !m.isDraft &&
            !m.isDeleted &&
            m.mailboxId != suppressMailboxId &&
            m.dateUtc.isAfter(oldest))
          m,
    ];
    if (unread.isEmpty) return;

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
