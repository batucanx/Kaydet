import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Şifrelerin saklandığı yer.
///
/// Android'de Keystore destekli `EncryptedSharedPreferences` kullanılır.
/// Şifre hiçbir zaman veritabanına, log'a veya kod içine yazılmaz.
abstract class SecureStore {
  Future<String?> readPassword(int accountId);
  Future<void> writePassword(int accountId, String password);
  Future<void> deletePassword(int accountId);

  Future<void> deleteAll();
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              // Varsayılan: Android Keystore destekli AES-GCM şifreleme.
              aOptions: AndroidOptions(resetOnError: true),
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

  @override
  Future<void> deleteAll() => _storage.deleteAll();
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
  Future<void> deleteAll() async {
    _passwords.clear();
  }
}
