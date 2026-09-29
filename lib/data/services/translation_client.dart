import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/result.dart';
import 'push_backend_client.dart' show PushBackendConfig;

/// Kaydet sunucusuna gönderilen çeviri isteği. Azure kimlik bilgisi bu
/// katmanda HİÇ yoktur: yalnızca sunucunun paylaşılan API anahtarı
/// ([PushBackendConfig]) kullanılır, Azure'a sunucu konuşur.
class TranslationRequest {
  const TranslationRequest({
    required this.userId,
    required this.messageId,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.subject,
    required this.segments,
  });

  /// Sunucudaki kullanıcı bazlı kotanın anahtarı (bkz. `TranslationUserId`).
  final String userId;
  final String messageId;

  /// `auto`: kaynak dili sağlayıcı algılar.
  final String sourceLanguage;
  final String targetLanguage;
  final String subject;

  /// Yalnızca çevrilebilir düz metin parçaları (HTML etiketi içermez).
  final List<String> segments;

  Map<String, Object?> toJson() => {
    'userId': userId,
    'messageId': messageId,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'subject': subject,
    'segments': segments,
  };
}

class TranslationResponse {
  const TranslationResponse({
    required this.translatedSubject,
    required this.segments,
    required this.cacheHit,
    required this.nearLimit,
  });

  final String translatedSubject;

  /// İstekteki parçalarla aynı sırada ve sayıda.
  final List<String> segments;

  /// Sunucu önbelleğinden geldi (Azure çağrılmadı).
  final bool cacheHit;

  /// Aylık kullanım uyarı eşiğine yaklaştı.
  final bool nearLimit;
}

/// Kaynak dil algılama sonucu.
class LanguageDetection {
  const LanguageDetection({required this.language, required this.nearLimit});

  /// Azure dil kodu (`en`, `de`, `zh-Hans`…); metin yoksa/algılanamadıysa `null`.
  final String? language;
  final bool nearLimit;
}

/// Sunucunun çeviri yüzeyi (bkz. `backend/src/app.ts` `POST /v1/translate`
/// ve `POST /v1/translate/detect`).
///
/// Repository katmanı kuralı gereği istisna fırlatmaz; her hata tipli bir
/// [AppFailure]'dır (`TranslationMonthlyLimitFailure`, `TranslationUserLimit-
/// Failure`, `TranslationNetworkFailure`, `TranslationUnavailableFailure`).
abstract interface class TranslationApi {
  Future<Result<TranslationResponse>> translate(TranslationRequest request);

  /// [sample]'ın dilini algılar (kısa bir örnek; sunucu ayrıca kırpar).
  Future<Result<LanguageDetection>> detectLanguage({
    required String userId,
    required String sample,
  });
}

/// `dart:io` üzerinden JSON konuşan istemci. Adres `https` olmak zorundadır;
/// yalnızca geliştirme için loopback düz HTTP'ye izin verir.
class HttpTranslationClient implements TranslationApi {
  HttpTranslationClient(
    this._config, {
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 45),
  }) : _http = httpClient ?? HttpClient(),
       _timeout = timeout;

  final PushBackendConfig _config;
  final HttpClient _http;
  final Duration _timeout;

  void close() => _http.close(force: true);

  @override
  Future<Result<TranslationResponse>> translate(TranslationRequest request) =>
      _post('/v1/translate', request.toJson(), (json) {
        final subject = json?['translatedSubject'];
        final segments = json?['segments'];
        if (subject is String &&
            segments is List &&
            segments.length == request.segments.length &&
            segments.every((s) => s is String)) {
          return Ok(
            TranslationResponse(
              translatedSubject: subject,
              segments: segments.cast<String>(),
              cacheHit: json?['cacheHit'] == true,
              nearLimit: json?['nearLimit'] == true,
            ),
          );
        }
        return const Err(
          TranslationUnavailableFailure(detail: 'beklenmedik yanıt gövdesi'),
        );
      });

  @override
  Future<Result<LanguageDetection>> detectLanguage({
    required String userId,
    required String sample,
  }) => _post('/v1/translate/detect', {'userId': userId, 'sample': sample}, (
    json,
  ) {
    final language = json?['language'];
    if (json != null && (language == null || language is String)) {
      return Ok(
        LanguageDetection(
          language: language as String?,
          nearLimit: json['nearLimit'] == true,
        ),
      );
    }
    return const Err(
      TranslationUnavailableFailure(detail: 'beklenmedik yanıt gövdesi'),
    );
    // Dil algılama açılışta çalışır: takılırsa bekletmeden vazgeçilir.
  }, timeout: const Duration(seconds: 10));

  /// JSON gönderir; ağ/HTTP hatalarını tipli [AppFailure]'a çevirir. Gövde
  /// metni loglanmaz/aktarılmaz.
  Future<Result<T>> _post<T>(
    String path,
    Map<String, Object?> body,
    Result<T> Function(Map<String, dynamic>? json) onOk, {
    Duration? timeout,
  }) async {
    final Uri uri;
    try {
      uri = _uri(path);
    } on StateError catch (e) {
      return Err(TranslationUnavailableFailure(detail: e.message));
    } on FormatException catch (e) {
      return Err(TranslationUnavailableFailure(detail: e.message));
    }

    try {
      final limit = timeout ?? _timeout;
      final http = await _http.postUrl(uri).timeout(limit);
      http.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.apiKey}',
      );
      http.headers.contentType = ContentType.json;
      http.add(utf8.encode(jsonEncode(body)));
      final response = await http.close().timeout(limit);
      final text = await response.transform(utf8.decoder).join().timeout(limit);
      return _parse(response.statusCode, text, onOk);
    } on TimeoutException catch (e) {
      return Err(TranslationNetworkFailure(detail: '$e'));
    } on SocketException catch (e) {
      return Err(TranslationNetworkFailure(detail: e.message));
    } on HandshakeException catch (e) {
      return Err(TranslationNetworkFailure(detail: e.message));
    } on HttpException catch (e) {
      return Err(TranslationNetworkFailure(detail: e.message));
    } catch (e) {
      // İstemci tarafı beklenmeyen hata da uygulamayı çökertmez.
      return Err(TranslationUnavailableFailure(detail: '$e'));
    }
  }

  Result<T> _parse<T>(
    int status,
    String body,
    Result<T> Function(Map<String, dynamic>? json) onOk,
  ) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      json = null;
    }

    if (status >= 200 && status < 300) return onOk(json);

    final code = json?['error'];
    if (status == 429) {
      return switch (code) {
        'TRANSLATION_USER_LIMIT_REACHED' => Err(
          const TranslationUserLimitFailure(),
        ),
        'TRANSLATION_MONTHLY_LIMIT_REACHED' => Err(
          const TranslationMonthlyLimitFailure(),
        ),
        _ => const Err(TranslationUnavailableFailure(detail: 'HTTP 429')),
      };
    }
    return Err(TranslationUnavailableFailure(detail: 'HTTP $status $code'));
  }

  Uri _uri(String path) {
    final base = Uri.parse(_config.baseUrl);
    final loopback =
        base.host == 'localhost' ||
        base.host == '127.0.0.1' ||
        base.host == '::1';
    if (base.scheme != 'https' && !loopback) {
      throw StateError('Çeviri sunucusu adresi https olmalı');
    }
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$basePath$path');
  }
}
