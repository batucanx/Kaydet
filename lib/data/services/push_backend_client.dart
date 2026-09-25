import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Push sunucusunun adresi ve paylaşılan API anahtarı.
///
/// Derleme zamanında verilir:
/// `--dart-define=PUSH_BACKEND_URL=https://... --dart-define=PUSH_API_KEY=...`
/// İkisi de yoksa anlık (sunucu tabanlı) bildirim özelliği tümüyle kapalıdır
/// ve uygulamanın diğer davranışları etkilenmez.
class PushBackendConfig {
  const PushBackendConfig({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  static PushBackendConfig? get compiled {
    const url = String.fromEnvironment('PUSH_BACKEND_URL');
    const key = String.fromEnvironment('PUSH_API_KEY');
    if (url.isEmpty || key.isEmpty) return null;
    return const PushBackendConfig(baseUrl: url, apiKey: key);
  }
}

/// Sunucuya kaydedilecek bir hesap. `clientAccountId`, uygulamadaki hesap
/// kimliğidir; bildirime dokunulunca doğru hesabı açmak için sunucudan
/// geri döner.
class RemotePushAccount {
  const RemotePushAccount({
    required this.apnsToken,
    required this.environment,
    required this.clientAccountId,
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    required this.password,
  });

  final String apnsToken;

  /// `development` ya da `production` (APNs ortamı; token ortama bağlıdır).
  final String environment;
  final int clientAccountId;
  final String host;
  final int port;

  /// `true`: doğrudan TLS (993). `false`: STARTTLS ya da düz bağlantı.
  final bool secure;
  final String username;
  final String password;
}

/// Sunucu 2xx dışında yanıt verdi.
class PushBackendException implements Exception {
  const PushBackendException(this.statusCode);

  final int statusCode;

  /// Yeniden denemenin anlamsız olduğu, isteğin kendisiyle ilgili hata.
  /// 401 (yanlış anahtar), 408 ve 429 geçici/yapılandırma sorunu sayılır.
  bool get isRequestRejected =>
      statusCode >= 400 &&
      statusCode < 500 &&
      statusCode != 401 &&
      statusCode != 408 &&
      statusCode != 429;

  @override
  String toString() => 'PushBackendException($statusCode)';
}

/// Push sunucusunun uygulamaya açtığı yüzey (bkz. `backend/src/app.ts`).
abstract interface class RemotePushApi {
  Future<void> upsertAccount(RemotePushAccount account);

  Future<void> deleteAccount({
    required String apnsToken,
    required int clientAccountId,
  });

  Future<void> deleteDevice(String apnsToken);
}

/// `dart:io` üzerinden JSON konuşan istemci.
///
/// İstekler IMAP şifresi taşıdığından adres `https` olmak zorundadır; yalnızca
/// geliştirme için loopback (`localhost`, `127.0.0.1`) düz HTTP'ye izin verir.
class HttpPushBackendClient implements RemotePushApi {
  HttpPushBackendClient(
    this._config, {
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _http = httpClient ?? HttpClient(),
       _timeout = timeout;

  final PushBackendConfig _config;
  final HttpClient _http;
  final Duration _timeout;

  @override
  Future<void> upsertAccount(RemotePushAccount account) =>
      _send('PUT', '/v1/accounts', {
        'apnsToken': account.apnsToken,
        'environment': account.environment,
        'clientAccountId': account.clientAccountId,
        'imap': {
          'host': account.host,
          'port': account.port,
          'secure': account.secure,
        },
        'username': account.username,
        'password': account.password,
      });

  @override
  Future<void> deleteAccount({
    required String apnsToken,
    required int clientAccountId,
  }) => _send('DELETE', '/v1/accounts', {
    'apnsToken': apnsToken,
    'clientAccountId': clientAccountId,
  });

  @override
  Future<void> deleteDevice(String apnsToken) =>
      _send('DELETE', '/v1/devices', {'apnsToken': apnsToken});

  void close() => _http.close(force: true);

  Uri _uri(String path) {
    final base = Uri.parse(_config.baseUrl);
    final loopback =
        base.host == 'localhost' ||
        base.host == '127.0.0.1' ||
        base.host == '::1';
    if (base.scheme != 'https' && !loopback) {
      throw StateError('Push sunucusu adresi https olmalı');
    }
    return base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}$path',
    );
  }

  Future<void> _send(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await _http.openUrl(method, _uri(path)).timeout(_timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${_config.apiKey}')
      ..contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(_timeout);
    // Gövde kullanılmasa da boşaltılmazsa bağlantı havuza dönmez.
    await response.drain<void>().timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PushBackendException(response.statusCode);
    }
  }
}
