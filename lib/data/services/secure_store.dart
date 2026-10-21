import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';

/// Şifrelerin saklandığı yer.
///
/// Android'de Keystore destekli `EncryptedSharedPreferences`, iOS'ta
/// Anahtar Zinciri (Keychain) kullanılır — ikisi de `flutter_secure_storage`
/// üzerinden, platforma özel ek kod gerekmeden. Şifre hiçbir zaman
/// veritabanına, log'a veya kod içine yazılmaz.
abstract class SecureStore {
  Future<String?> readPassword(int accountId);
  Future<void> writePassword(int accountId, String password);
  Future<void> deletePassword(int accountId);

  /// [error] depodaki anahtarın KALICI olarak bozulduğunu gösteriyorsa (ör.
  /// yarım kalan geçiş sonrası `Failed to unwrap key`, Keystore `-1000`) depoyu
  /// sıfırlar ve `true` döner; şifreler zaten okunamadığından kullanıcı
  /// yeniden giriş yapmalıdır. Geçici hatalarda dokunmaz, `false` döner.
  Future<bool> resetIfCorrupt(Object error);
}

/// Uygulamanın tüm gizli verileri (şifreler, kurulum sırrı) için ortak depo
/// ayarı; açıklamalar `FlutterSecureStore` ile aynı kuralı izler.
const kaydetSecureStorage = FlutterSecureStorage(
  // Android Keystore destekli AES-GCM şifreleme.
  //
  // `resetOnError` KAPALI olmalı: açıkken geçici bir Keystore/
  // şifre çözme hatası (yeniden başlatma sonrası anahtar hazır
  // değil, eklenti güncellemesiyle algoritma değişimi) TÜM
  // hesapların şifrelerini kalıcı siler ve kullanıcı güncelleme
  // ya da yeniden başlatmadan sonra çıkış yapmış gibi kalır.
  // Kapalıyken okuma hata FIRLATIR; veri korunur ve bir sonraki
  // denemede yeniden okunur (bkz. `MailConnection._credentialFor`).
  // Algoritma değişirse veri silinmez, yedekli olarak taşınır.
  aOptions: AndroidOptions(
    resetOnError: false,
    // Algoritma değişmediği için geçiş KAPALI: eklenti, ilk kurulumda bile
    // "algoritma değişti" sanıp boş depoda yedekli geçiş başlatıp anahtarı
    // bozabiliyor.
    migrateOnAlgorithmChange: false,
    migrateWithBackup: false,
  ),
  // iOS: Cihaz kilitliyken gelen APNs push ve arka plan senkronu
  // (bkz. pushBackgroundSync / runBackgroundSync) şifreleri okuyabilsin.
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);

Future<void>? _ready;

/// Android Keystore anahtarı İLK erişimde üretilir. İki yer (şifreler ve kurulum
/// kimliği) aynı anda ilk erişimi yaparsa aynı anahtar iki kez üretilir ve
/// sarılı anahtar bozulur (`Failed to unwrap key`, Keystore `-1000`). Bu yüzden
/// her erişim önce bu tek seferlik ve tekil (single-flight) hazırlığı bekler.
Future<void> ensureSecureStorageReady() {
  final inFlight = _ready ??= kaydetSecureStorage
      .containsKey(key: 'kaydet_storage_probe')
      .then((_) {});
  return inFlight.catchError((Object error) {
    if (identical(_ready, inFlight)) _ready = null;
    throw error;
  });
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? kaydetSecureStorage;

  final FlutterSecureStorage _storage;

  String _passwordKey(int accountId) => 'kaydet_account_${accountId}_password';

  /// Google girişi kaldırılmadan önce yazılmış OAuth token anahtarı. Yalnızca
  /// eski kurulumlarda kalan yenileme token'ının hesapla birlikte silinmesi
  /// için okunur.
  String _legacyOauthKey(int accountId) => 'kaydet_account_${accountId}_oauth';

  // Keystore işlemleri (özellikle şifre çözme) eşzamanlı çağrıldığında bazı
  // cihazlarda `KeyStoreException -1000 (UNKNOWN_ERROR)` verir: okumalar tek
  // tek sıraya alınır, başarılı okuma süreç içinde önbelleğe alınır.
  static final Lock _lock = Lock();
  static final Map<int, String> _cache = {};

  @override
  Future<String?> readPassword(int accountId) => _lock.synchronized(() async {
    await ensureSecureStorageReady();
    final cached = _cache[accountId];
    if (cached != null) return cached;
    final value = await _storage.read(key: _passwordKey(accountId));
    if (value != null) _cache[accountId] = value;
    return value;
  });

  @override
  Future<void> writePassword(int accountId, String password) =>
      _lock.synchronized(() async {
        await ensureSecureStorageReady();
        await _storage.write(key: _passwordKey(accountId), value: password);
        _cache[accountId] = password;
      });

  @override
  Future<void> deletePassword(int accountId) async {
    _cache.remove(accountId);
    await _storage.delete(key: _passwordKey(accountId));
    await _storage.delete(key: _legacyOauthKey(accountId));
  }

  @override
  Future<bool> resetIfCorrupt(Object error) async {
    final text = '$error';
    final permanent =
        text.contains('Failed to unwrap key') ||
        text.contains('Key mismatch') ||
        text.contains('-1000');
    if (!permanent) return false;
    try {
      await _lock.synchronized(() async {
        _cache.clear();
        // Bozuk anahtarla `deleteAll` de aynı hatayı verir; `resetOnError`
        // AÇIK bir örnekle depoya erişmek eklentiyi verileri silmeye zorlar.
        const resetting = FlutterSecureStorage(
          aOptions: AndroidOptions(resetOnError: true),
        );
        try {
          await resetting.deleteAll();
        } on Object catch (_) {
          await resetting.read(key: 'kaydet_reset_probe');
        }
      });
      return true;
    } on Object catch (_) {
      return false;
    }
  }
}

/// Testler ve önizleme için bellek içi uygulama.
class InMemorySecureStore implements SecureStore {
  final Map<int, String> _passwords = {};

  @override
  Future<String?> readPassword(int accountId) async => _passwords[accountId];

  @override
  Future<void> writePassword(int accountId, String password) async {
    _passwords[accountId] = password;
  }

  @override
  Future<void> deletePassword(int accountId) async {
    _passwords.remove(accountId);
  }

  @override
  Future<bool> resetIfCorrupt(Object error) async => false;
}
