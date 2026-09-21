/// Ana isolate ile ön plan servisi isolate'i arasındaki mesaj sözleşmesi.
///
/// İki taraf ayrı isolate'lerde yaşar ve yalnızca JSON'a dönüşebilir
/// `Map`'ler değiş tokuş eder (bkz. `flutter_foreground_task`). Anahtarları
/// iki yerde elle yazmak sessiz uyumsuzluk üretirdi; bu yüzden tek yerde.
abstract final class PushProtocol {
  static const String typeKey = 'type';

  // ---- ana isolate → servis

  /// Arayüz durumu: kullanıcı şu an hangi Gelen Kutusu'nu görüyor?
  /// `inboxId` yoksa (`null`) hiçbir Gelen Kutusu görünmüyordur.
  static const String ui = 'ui';
  static const String inboxIdKey = 'inboxId';

  /// Hesap eklendi/silindi/yeniden giriş yapıldı — izleyiciler yeniden kurulur.
  static const String accounts = 'accounts';

  // ---- servis → ana isolate

  /// Servis ayağa kalktı; ana isolate güncel arayüz durumunu göndermeli
  /// (servis başlarken gelen mesajlar kaybolabilir, bu yüzden servis ister).
  static const String hello = 'hello';

  /// Servis veritabanına yazdı. Drift akışları isolate'ler arası değişikliği
  /// kendiliğinden görmez; ana isolate tabloları "güncellendi" işaretler.
  static const String dbChanged = 'db_changed';

  static Map<String, Object?> message(
    String type, [
    Map<String, Object?> data = const {},
  ]) => {typeKey: type, ...data};
}
