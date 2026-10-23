import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';

/// Hangi iletilerin bildirildiğinin kalıcı defteri (hesap başına bir "su
/// çizgisi").
///
/// **Sorun:** bildirim kararı eskiden yalnızca eşitlemenin döndürdüğü
/// `SyncOutcome.newMessageIds`'e bağlıydı: "bu turda yeni eklenen iletiler".
/// İleti bir kez yerele yazıldı mı, sonraki hiçbir tur onu "yeni" görmez. Yani
/// iletiyi çeken yol bildirimi üretmeden önce biterse bildirim SONSUZA DEK
/// kaybolurdu:
///  - "Tüm Hesaplar" görünümü etkin olmayan hesapların Gelen Kutusu'nu
///    bildirimsiz eşitliyordu (uygulama kapanınca o hesaplar sessiz kalıyordu);
///  - FCM işçisi iletiyi yazdıktan sonra gövde önizlemesini indirirken
///    sistem tarafından durdurulur ya da zaman aşımına uğrar, yeniden deneme
///    iletiyi artık "yeni" bulmaz;
///  - iki isolate (arayüz + işçi/servis) aynı iletiyi yarışır, biri alır.
///
/// **Çözüm:** bildirim "bu turda ne geldi"ye değil, kalıcı duruma bağlanır:
/// hesabın Gelen Kutusu'nda, su çizgisinden büyük UID'li ve hâlâ okunmamış her
/// ileti bildirilmemiş sayılır. Su çizgisi yalnızca bildirim gösterildikten
/// SONRA ilerler. Hangi yol eşitlerse eşitlesin, bir sonraki bildirim çağrısı
/// (herhangi bir isolate'ten) kaçanı yakalar.
///
/// Bildirimler ileti kimliğiyle (`show(id: message.id)`) gösterildiğinden iki
/// isolate aynı iletiyi aynı anda bildirse bile ikinci gösterim birincinin
/// yerini alır (çift bildirim olmaz). Su çizgisi UIDVALIDITY ile birlikte
/// saklanır; değişirse eski UID'ler anlamsızdır ve çizgi sıfırlanır.
/// [NotificationLedger.view] sonucu.
class LedgerView {
  const LedgerView({this.mark, this.pendingIds = const []});

  /// Bildirilmiş en yüksek UID; `null` ise defter henüz kurulmamış.
  final int? mark;

  /// Çizginin ötesindeki, hâlâ okunmamış (bildirilmemiş) iletilerin kimlikleri.
  final List<int> pendingIds;
}

class NotificationLedger {
  NotificationLedger({
    required AppDatabase database,
    Future<SharedPreferences> Function()? preferences,
  }) : _db = database,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final AppDatabase _db;
  final Future<SharedPreferences> Function() _preferences;

  static String _key(int accountId) => 'kaydet.notified.$accountId';

  /// Hesabın defter görünümü: su çizgisi ve çizginin ötesindeki okunmamış
  /// iletiler. Çizgi yokken (ilk çalışma) ya da UIDVALIDITY değişmişken
  /// [LedgerView.mark] `null`, bekleyen liste boştur: geçmiş iletiler bildirilmez.
  Future<LedgerView> view(int accountId) async {
    final inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (inbox == null) return const LedgerView();
    final mark = await _read(accountId);
    if (mark == null || mark.uidValidity != (inbox.uidValidity ?? 0)) {
      return const LedgerView();
    }
    return LedgerView(
      mark: mark.uid,
      pendingIds: await _db.unseenMessageIdsAfterUid(inbox.id, mark.uid),
    );
  }

  /// Hesabın su çizgisi yoksa (ya da UIDVALIDITY değiştiyse) bugüne kurar. Yeni
  /// ileti olmayan sıradan turlarda her seferinde disk okumamak için kurulu
  /// olduğu bilinen hesaplar bellekte hatırlanır.
  Future<void> ensureInitialized(int accountId) async {
    if (_known.contains(accountId)) return;
    final inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (inbox == null) return;
    final mark = await _read(accountId);
    if (mark != null && mark.uidValidity == (inbox.uidValidity ?? 0)) {
      _known.add(accountId);
      return;
    }
    await advance(accountId);
    _known.add(accountId);
  }

  final Set<int> _known = {};

  /// Su çizgisini Gelen Kutusu'ndaki en yüksek UID'ye taşır. Bildirim
  /// GÖSTERİLDİKTEN (ya da bilinçli olarak atlandıktan) sonra çağrılır.
  Future<void> advance(int accountId) async {
    final inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (inbox == null) return;
    final highest = await _db.highestUid(inbox.id);
    if (highest == null) return;
    final validity = inbox.uidValidity ?? 0;
    final mark = await _read(accountId);
    if (mark != null && mark.uidValidity == validity && mark.uid >= highest) {
      return;
    }
    await _write(accountId, validity, highest);
  }

  /// Defter okunamazsa (eklenti yok, disk hatası) "çizgi yok" sayılır: bildirim
  /// yalnızca eşitlemenin kendi "yeni ileti" listesine düşer (eski davranış);
  /// defter hiçbir zaman bildirimi engellemez ya da hata fırlatmaz.
  Future<({int uidValidity, int uid})?> _read(int accountId) async {
    try {
      final prefs = await _preferences();
      // Başka bir isolate (arka plan işçisi/servis) yazmış olabilir; eklenti
      // isolate başına önbellek tutar.
      await prefs.reload();
      final raw = prefs.getString(_key(accountId));
      if (raw == null) return null;
      final parts = raw.split(':');
      if (parts.length != 2) return null;
      final validity = int.tryParse(parts[0]);
      final uid = int.tryParse(parts[1]);
      if (validity == null || uid == null) return null;
      return (uidValidity: validity, uid: uid);
    } on Object catch (_) {
      return null;
    }
  }

  Future<void> _write(int accountId, int validity, int uid) async {
    try {
      final prefs = await _preferences();
      await prefs.setString(_key(accountId), '$validity:$uid');
    } on Object catch (_) {
      // Yazılamadı: bir sonraki bildirim turu yeniden dener.
    }
  }
}
