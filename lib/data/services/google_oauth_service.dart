import 'dart:convert';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;

import '../../core/result.dart';

/// Bir hesabın OAuth erişim + yenileme token'ı.
///
/// [SecureStore]'a JSON olarak yazılır — şifre gibi veritabanına asla
/// düşmez (bkz. `secure_store.dart`).
class OAuthTokenSet {
  const OAuthTokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// Erişim token'ı süresi dolmuş mu? 2 dakikalık pay bırakılır — tam
  /// sınırda bağlanmaya çalışıp sunucudan reddedilmektense biraz erken
  /// yenilemek daha güvenli.
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 2)));

  factory OAuthTokenSet.fromJson(Map<String, dynamic> json) => OAuthTokenSet(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

/// Google girişi başarılı olunca elde edilenler.
class GoogleSignInResult {
  const GoogleSignInResult({required this.email, required this.tokens});
  final String email;
  final OAuthTokenSet tokens;
}

/// Google hesabıyla OAuth2 girişi ve token yenileme.
///
/// IMAP/SMTP servislerinin kendisi Google'a özel değildir (bkz.
/// `imap_service.dart`, `smtp_service.dart`) — onlar yalnızca
/// [MailCredential] üzerinden çalışır. Bu sınıf tek başına token
/// almak/yenilemekten sorumludur; sunucu adresleri sabittir çünkü Gmail
/// için kullanıcıdan IMAP/SMTP host bilgisi istenmez.
///
/// Kayıt: Google Cloud Console, proje "kaydet" — bkz.
/// `docs/plan/05-em-client-paritesi.md`.
class GoogleOAuthService {
  GoogleOAuthService({FlutterAppAuth? appAuth, http.Client? httpClient})
      : _appAuth = appAuth ?? FlutterAppAuth(),
        _http = httpClient ?? http.Client();

  final FlutterAppAuth _appAuth;
  final http.Client _http;

  /// Google Cloud Console'da kayıtlı Android OAuth istemci kimliği.
  static const String clientId =
      '856471546230-onihb0lsnk7qh1apqbcv7qt5no3m6dod.apps.googleusercontent.com';

  /// Google'ın Android istemcileri için beklediği yönlendirme biçimi:
  /// istemci kimliğinin tersine çevrilmiş hâli. `android/app/build.gradle.kts`
  /// içindeki `appAuthRedirectScheme` ile birebir aynı olmalı.
  static const String _redirectUrl =
      'com.googleusercontent.apps.856471546230-onihb0lsnk7qh1apqbcv7qt5no3m6dod:/oauth2redirect';

  static const AuthorizationServiceConfiguration _serviceConfiguration =
      AuthorizationServiceConfiguration(
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
  );

  static const List<String> _scopes = [
    'https://mail.google.com/',
    'email',
    'profile',
    'openid',
  ];

  static const String imapHost = 'imap.gmail.com';
  static const int imapPort = 993;
  static const String smtpHost = 'smtp.gmail.com';
  static const int smtpPort = 465;

  /// Tarayıcıya yönlendirip kullanıcının onayını alır.
  ///
  /// Google yalnızca ilk onayda (ya da onay zorlanınca) bir yenileme
  /// token'ı döner; `promptValues: ['consent']` + `access_type=offline` bunu
  /// garanti eder — aksi hâlde kullanıcı token süresi dolduğunda sessizce
  /// yenilenemez, tekrar tarayıcıya atılır.
  Future<Result<GoogleSignInResult>> signIn() async {
    try {
      final response = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          clientId,
          _redirectUrl,
          serviceConfiguration: _serviceConfiguration,
          scopes: _scopes,
          promptValues: const ['consent'],
          additionalParameters: const {'access_type': 'offline'},
        ),
      );

      final accessToken = response.accessToken;
      final refreshToken = response.refreshToken;
      final expiresAt = response.accessTokenExpirationDateTime;
      if (accessToken == null || refreshToken == null || expiresAt == null) {
        return const Err(
          AuthFailure(detail: 'Google yanıtı eksik token içeriyor'),
        );
      }

      final email = await _fetchEmail(accessToken);
      if (email == null) {
        return const Err(
          AuthFailure(detail: 'Google e-posta adresi alınamadı'),
        );
      }

      return Ok(
        GoogleSignInResult(
          email: email,
          tokens: OAuthTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
          ),
        ),
      );
    } on FlutterAppAuthUserCancelledException {
      return const Err(AuthFailure(detail: 'Google girişi iptal edildi'));
    } on Object catch (error) {
      return Err(ConnectionFailure(detail: '$error'));
    }
  }

  /// Süresi dolan erişim token'ını yeniler.
  ///
  /// Google yenilemede genelde yeni bir refresh token döndürmez; eskisi
  /// geçerliliğini korur, bu yüzden `response.refreshToken` boşsa eskisi
  /// aynen taşınır.
  Future<Result<OAuthTokenSet>> refresh(String refreshToken) async {
    try {
      final response = await _appAuth.token(
        TokenRequest(
          clientId,
          _redirectUrl,
          serviceConfiguration: _serviceConfiguration,
          refreshToken: refreshToken,
          scopes: _scopes,
        ),
      );

      final accessToken = response.accessToken;
      final expiresAt = response.accessTokenExpirationDateTime;
      if (accessToken == null || expiresAt == null) {
        return const Err(AuthFailure(detail: 'Google yenileme yanıtı eksik'));
      }

      return Ok(
        OAuthTokenSet(
          accessToken: accessToken,
          refreshToken: response.refreshToken ?? refreshToken,
          expiresAt: expiresAt,
        ),
      );
    } on Object catch (error) {
      return Err(_mapRefreshError(error));
    }
  }

  AppFailure _mapRefreshError(Object error) {
    final text = '$error';
    if (text.contains('invalid_grant')) {
      // Refresh token iptal edilmiş veya süresi dolmuş (kullanıcı erişimi
      // geri aldı, şifresini değiştirdi vb.) — yeniden giriş şart.
      return const AuthFailure(
        detail: 'Google oturumu geçersiz, yeniden giriş gerekli',
      );
    }
    return ConnectionFailure(detail: text);
  }

  Future<String?> _fetchEmail(String accessToken) async {
    try {
      final response = await _http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return json['email'] as String?;
    } on Object {
      return null;
    }
  }

  void dispose() => _http.close();
}
