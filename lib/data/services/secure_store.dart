import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
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
                migrateOnAlgorithmChange: true,
                migrateWithBackup: true,
              ),
              // iOS: Cihaz kilitliyken gelen APNs push ve arka plan senkronu
              // (bkz. pushBackgroundSync / runBackgroundSync) şifreleri okuyabilsin.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  String _passwordKey(int accountId) =>
      'kaydet_account_${accountId}_password';

  /// Google girişi kaldırılmadan önce yazılmış OAuth token anahtarı. Yalnızca
  /// eski kurulumlarda kalan yenileme token'ının hesapla birlikte silinmesi
  /// için okunur.
  String _legacyOauthKey(int accountId) =>
      'kaydet_account_${accountId}_oauth';

  @override
  Future<String?> readPassword(int accountId) =>
      _storage.read(key: _passwordKey(accountId));

  @override
  Future<void> writePassword(int accountId, String password) =>
      _storage.write(key: _passwordKey(accountId), value: password);

  @override
  Future<void> deletePassword(int accountId) async {
    await _storage.delete(key: _passwordKey(accountId));
    await _storage.delete(key: _legacyOauthKey(accountId));
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
}
