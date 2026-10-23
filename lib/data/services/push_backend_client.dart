import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'install_credentials.dart';

/// Push sunucusunun adresi ve paylaşılan API anahtarı.
///
/// Gerçek değerler `lib/app/push_backend_config.dart`de tutulur (git'e
/// eklenmez, bkz. o dosyanın yanındaki `.example` şablonu) — bu sınıf yalnızca
/// taşıyıcı, kaynağı bilmez.
class PushBackendConfig {
  const PushBackendConfig({
    required this.baseUrl,
    required this.apiKey,
    this.credentials,
  });

  final String baseUrl;
  final String apiKey;

  /// Bu kuruluma özel kimlik (bkz. `install_credentials.dart`). Sunucu
  /// `/health` dışındaki her istekte bunu ister; testlerde `null` olabilir.
  final InstallCredentialsSource? credentials;
}

/// `Authorization` ve kurulum başlıklarını ekler. Paylaşılan API anahtarı
/// uygulamadan çıkarılabilir; kurulum sırrı ise her kuruluma özeldir ve sunucu
/// kotaları/limitleri buna bağlar.
Future<void> applyBackendAuth(
  HttpClientRequest request,
  PushBackendConfig config,
) async {
  request.headers.set(
    HttpHeaders.authorizationHeader,
    'Bearer ${config.apiKey}',
  );
  final install = await config.credentials?.load();
  if (install != null) {
    request.headers.set('x-install-id', install.id);
    request.headers.set('x-install-secret', install.secret);
  }
}

/// Sunucuya kaydedilecek bir hesap. `clientAccountId`, uygulamadaki hesap
/// kimliğidir; bildirime dokunulunca doğru hesabı açmak için sunucudan
/// geri döner.
class RemotePushAccount {
  const RemotePushAccount({
    required this.pushToken,
    required this.environment,
    required this.clientAccountId,
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    required this.password,
  });

  /// iOS'ta APNs, Android'de FCM kayıt token'ı.
  final String pushToken;

  /// `development` ya da `production` (APNs ortamı; token ortama bağlıdır).
  /// Android'de her zaman `production`.
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

/// Sunucunun bir hesabı izleme durumu (bkz. `backend/src/watcher.ts`
/// `WatchStatus`). "Kayıtlı" olmak "izleniyor" demek DEĞİLDİR: sunucu kimlik
/// bilgisini reddedilmiş bulabilir ya da posta sunucusuna ulaşamayabilir.
enum ServerWatchStatus {
  /// Bağlanıyor ya da kademeli başlatma sırasında bekliyor; geçici.
  connecting,

  /// INBOX açık, IDLE'da bekleniyor: yeni ileti anında bildirilir.
  watching,

  /// Posta sunucusu kimlik bilgisini reddetti (şifre değişmiş ya da sağlayıcı
  /// sunucunun IP'sini engelliyor). Sunucu seyrek yeniden dener; istemci taze
  /// şifreyle yeniden kaydederek hemen deneyebilir.
  authFailed,

  /// Posta sunucusuna art arda bağlanılamadı.
  unreachable,

  /// Kayıt var ama sunucuda çalışan bir izleyici yok.
  stopped,

  /// Eski sunucu sürümü durum bildirmiyor.
  unknown;

  /// Sunucu bu hesabın yeni iletisini şu an yakalayamaz.
  bool get isUnhealthy =>
      this == authFailed || this == unreachable || this == stopped;

  /// Hesabı taze bilgilerle yeniden kaydetmek durumu düzeltebilir.
  bool get repairableByReupload => this == authFailed || this == stopped;

  static ServerWatchStatus parse(Object? value) => switch (value) {
    'watching' => watching,
    'connecting' => connecting,
    'auth_failed' => authFailed,
    'unreachable' => unreachable,
    'stopped' => stopped,
    _ => unknown,
  };
}

/// Sunucuda kayıtlı bir hesap ve izleme durumu.
class RegisteredAccount {
  const RegisteredAccount(this.clientAccountId, this.status);

  final int clientAccountId;
  final ServerWatchStatus status;
}

/// Push sunucusunun uygulamaya açtığı yüzey (bkz. `backend/src/app.ts`).
abstract interface class RemotePushApi {
  String get baseUrl;

  /// Cihazın sunucuda kayıtlı hesapları ve her birinin izleme durumu.
  Future<List<RegisteredAccount>> listRegisteredAccounts(String pushToken);

  Future<void> upsertAccount(RemotePushAccount account);

  Future<void> deleteAccount({
    required String pushToken,
    required int clientAccountId,
  });

  Future<void> deleteDevice(String pushToken);
}

/// `dart:io` üzerinden JSON konuşan istemci.
///
/// İstekler IMAP şifresi taşıdığından adres `https` olmak zorundadır; yalnızca
/// geliştirme için loopback (`localhost`, `127.0.0.1`) düz HTTP'ye izin verir.
class HttpPushBackendClient implements RemotePushApi {
  HttpPushBackendClient(
    this._config, {
    this.platform = 'ios',
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _http = httpClient ?? HttpClient(),
       _timeout = timeout;

  final PushBackendConfig _config;

  /// `ios` (APNs) ya da `android` (FCM); token'ın hangi servise ait olduğunu
  /// sunucuya bildirir.
  final String platform;
  final HttpClient _http;
  final Duration _timeout;

  @override
  String get baseUrl => _config.baseUrl;

  @override
  Future<List<RegisteredAccount>> listRegisteredAccounts(
    String pushToken,
  ) async {
    final res = await _send(
      'GET',
      '/v1/accounts?pushToken=${Uri.encodeQueryComponent(pushToken)}'
      '&platform=$platform',
    );
    final decoded = jsonDecode(res) as Map<String, dynamic>;
    final detailed = decoded['accounts'];
    if (detailed is List<dynamic>) {
      return [
        for (final entry in detailed)
          if (entry is Map<String, dynamic>)
            RegisteredAccount(
              (entry['clientAccountId'] as num).toInt(),
              ServerWatchStatus.parse(entry['status']),
            ),
      ];
    }
    // Durum bildirmeyen eski sunucu: yalnızca kimlikler.
    final list = decoded['clientAccountIds'] as List<dynamic>? ?? const [];
    return [
      for (final id in list)
        RegisteredAccount((id as num).toInt(), ServerWatchStatus.unknown),
    ];
  }

  @override
  Future<void> upsertAccount(RemotePushAccount account) =>
      _send('PUT', '/v1/accounts', {
        'pushToken': account.pushToken,
        'platform': platform,
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
    required String pushToken,
    required int clientAccountId,
  }) => _send('DELETE', '/v1/accounts', {
    'pushToken': pushToken,
    'platform': platform,
    'clientAccountId': clientAccountId,
  });

  @override
  Future<void> deleteDevice(String pushToken) => _send('DELETE', '/v1/devices', {
    'pushToken': pushToken,
    'platform': platform,
  });

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
    final questionIdx = path.indexOf('?');
    final rawPath = questionIdx >= 0 ? path.substring(0, questionIdx) : path;
    final queryString = questionIdx >= 0
        ? path.substring(questionIdx + 1)
        : null;
    final mergedPath = '${base.path.replaceAll(RegExp(r'/+$'), '')}$rawPath';
    return base.replace(path: mergedPath, query: queryString);
  }

  Future<String> _send(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = await _http.openUrl(method, _uri(path)).timeout(_timeout);
    await applyBackendAuth(request, _config);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(_timeout);
    final responseBody = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PushBackendException(response.statusCode);
    }
    return responseBody;
  }
}
