import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'google_oauth_service.dart';

/// Şifrelerin ve OAuth token'larının saklandığı yer.
///
/// Android'de Keystore destekli `EncryptedSharedPreferences` kullanılır.
/// Şifre ve token hiçbir zaman veritabanına, log'a veya kod içine yazılmaz.
abstract class SecureStore {
  Future<String?> readPassword(int accountId);
  Future<void> writePassword(int accountId, String password);
  Future<void> deletePassword(int accountId);

  /// OAuth hesapları için erişim + yenileme token'ı, birlikte saklanır.
  Future<OAuthTokenSet?> readOAuthTokens(int accountId);
  Future<void> writeOAuthTokens(int accountId, OAuthTokenSet tokens);
  Future<void> deleteOAuthTokens(int accountId);

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
  String _oauthKey(int accountId) => 'kaydet_account_${accountId}_oauth';

  @override
  Future<String?> readPassword(int accountId) =>
      _storage.read(key: _passwordKey(accountId));

  @override
  Future<void> writePassword(int accountId, String password) =>
      _storage.write(key: _passwordKey(accountId), value: password);

  @override
  Future<void> deletePassword(int accountId) =>
      _storage.delete(key: _passwordKey(accountId));

  @override
  Future<OAuthTokenSet?> readOAuthTokens(int accountId) async {
    final raw = await _storage.read(key: _oauthKey(accountId));
    if (raw == null) return null;
    return OAuthTokenSet.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> writeOAuthTokens(int accountId, OAuthTokenSet tokens) =>
      _storage.write(
        key: _oauthKey(accountId),
        value: jsonEncode(tokens.toJson()),
      );

  @override
  Future<void> deleteOAuthTokens(int accountId) =>
      _storage.delete(key: _oauthKey(accountId));

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

/// Testler ve önizleme için bellek içi uygulama.
class InMemorySecureStore implements SecureStore {
  final Map<int, String> _passwords = {};
  final Map<int, OAuthTokenSet> _oauthTokens = {};

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
  Future<OAuthTokenSet?> readOAuthTokens(int accountId) async =>
      _oauthTokens[accountId];

  @override
  Future<void> writeOAuthTokens(int accountId, OAuthTokenSet tokens) async {
    _oauthTokens[accountId] = tokens;
  }

  @override
  Future<void> deleteOAuthTokens(int accountId) async {
    _oauthTokens.remove(accountId);
  }

  @override
  Future<void> deleteAll() async {
    _passwords.clear();
    _oauthTokens.clear();
  }
}
