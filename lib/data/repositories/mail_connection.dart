import 'dart:async';

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import '../database/tables.dart';
import '../services/google_oauth_service.dart';
import '../services/imap_service.dart';
import '../services/secure_store.dart';

/// Hesap başına tek IMAP bağlantısı.
///
/// Her ekranın kendi bağlantısını açması, sunucunun eşzamanlı bağlantı
/// limitine takılmanın ("Too many connections") birinci sebebidir. Bu sınıf
/// tek bağlantıyı yaşatır, koptuğunda üstel geri çekilmeyle yeniden bağlar
/// ve 4 dakikada bir NOOP göndererek sunucunun oturumu düşürmesini önler.
class MailConnection {
  MailConnection({
    required AppDatabase database,
    required SecureStore secureStore,
    required ImapService imapService,
    required GoogleOAuthService googleOAuth,
  })  : _db = database,
        _secureStore = secureStore,
        _imap = imapService,
        _googleOAuth = googleOAuth;

  final AppDatabase _db;
  final SecureStore _secureStore;
  final ImapService _imap;
  final GoogleOAuthService _googleOAuth;

  Timer? _keepAlive;
  int? _accountId;
  ServerCapabilities _capabilities = ServerCapabilities.unknown;
  int _reconnectAttempt = 0;
  Completer<Result<void>>? _connecting;

  ImapService get imap => _imap;
  ServerCapabilities get capabilities => _capabilities;
  bool get isConnected => _imap.isConnected;
  Stream<void> get serverChanges => _imap.serverChanges;

  /// Bağlantının hazır olduğundan emin olur.
  ///
  /// Aynı anda birden çok çağrı gelirse yalnızca biri bağlanır, diğerleri
  /// aynı sonucu bekler.
  Future<Result<void>> ensureConnected(int accountId) async {
    if (_imap.isConnected && _accountId == accountId) return okVoid;

    final pending = _connecting;
    if (pending != null && _accountId == accountId) return pending.future;

    final completer = Completer<Result<void>>();
    _connecting = completer;
    _accountId = accountId;

    try {
      final result = await _connect(accountId);
      completer.complete(result);
      return result;
    } finally {
      _connecting = null;
    }
  }

  Future<Result<void>> _connect(int accountId) async {
    final account = await _db.accountById(accountId);
    if (account == null) {
      return const Err(AuthFailure(detail: 'hesap bulunamadı'));
    }

    final credentialResult = await _credentialFor(account);
    if (credentialResult is Err<MailCredential>) {
      return Err(credentialResult.failure);
    }

    final config = MailServerConfig(
      host: account.imapHost,
      port: account.imapPort,
      security: account.imapSecurity,
      username: account.username,
      credential: (credentialResult as Ok<MailCredential>).value,
    );

    final result = await _imap.connect(config);
    return result.fold(
      (capabilities) {
        _capabilities = capabilities;
        _reconnectAttempt = 0;
        _startKeepAlive();
        return okVoid;
      },
      (failure) {
        _stopKeepAlive();
        return Err(failure);
      },
    );
  }

  /// Bağlantı koptuysa üstel geri çekilmeyle yeniden dener.
  ///
  /// Gecikmeler: 1s, 2s, 4s, 8s, 16s, 32s, sonra 60s sabit.
  Future<Result<void>> reconnectWithBackoff(int accountId) async {
    final attempt = _reconnectAttempt;
    final seconds = attempt >= 6 ? 60 : (1 << attempt);
    _reconnectAttempt = attempt + 1;
    await Future<void>.delayed(Duration(seconds: seconds));
    return ensureConnected(accountId);
  }

  /// Geri çekilme sayacını sıfırlar (ağ geri geldiğinde).
  void resetBackoff() => _reconnectAttempt = 0;

  void _startKeepAlive() {
    _stopKeepAlive();
    // Sunucular genelde 30 dakikada boş oturumu düşürür; 4 dakika güvenli.
    _keepAlive = Timer.periodic(const Duration(minutes: 4), (_) async {
      if (!_imap.isConnected) return;
      await _imap.noop();
    });
  }

  void _stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  Future<void> disconnect() async {
    _stopKeepAlive();
    _accountId = null;
    _capabilities = ServerCapabilities.unknown;
    await _imap.disconnect();
  }

  /// Hesabın SMTP ayarlarını güvenli depodaki kimlik bilgisiyle birleştirir.
  Future<MailServerConfig?> smtpConfig(int accountId) async {
    final account = await _db.accountById(accountId);
    if (account == null) return null;
    final credentialResult = await _credentialFor(account);
    if (credentialResult is Err<MailCredential>) return null;
    return MailServerConfig(
      host: account.smtpHost,
      port: account.smtpPort,
      security: account.smtpSecurity,
      username: account.username,
      credential: (credentialResult as Ok<MailCredential>).value,
    );
  }

  /// Hesabın kimlik bilgisini üretir.
  ///
  /// OAuth hesaplarında süresi dolmuş erişim token'ı burada, bağlanmadan
  /// önce sessizce yenilenir ve güvenli depo güncellenir — aksi hâlde
  /// sunucu genel bir "kimlik doğrulama başarısız" hatası döner ve kullanıcı
  /// gerçek sebebi (token süresi doldu) hiç göremez.
  Future<Result<MailCredential>> _credentialFor(AccountRow account) async {
    if (account.authMethod == AuthMethod.password) {
      final password = await _secureStore.readPassword(account.id);
      if (password == null || password.isEmpty) {
        return const Err(AuthFailure(detail: 'kayıtlı şifre yok'));
      }
      return Ok(PasswordCredential(password));
    }

    var tokens = await _secureStore.readOAuthTokens(account.id);
    if (tokens == null) {
      return const Err(AuthFailure(detail: 'kayıtlı Google oturumu yok'));
    }
    if (tokens.isExpired) {
      final refreshed = await _googleOAuth.refresh(tokens.refreshToken);
      if (refreshed is Err<OAuthTokenSet>) return Err(refreshed.failure);
      tokens = (refreshed as Ok<OAuthTokenSet>).value;
      await _secureStore.writeOAuthTokens(account.id, tokens);
    }
    return Ok(OAuthCredential(tokens.accessToken));
  }
}

/// Bir hesabın klasör yolu yardımcıları.
extension MailboxPathHelpers on MailboxRow {
  /// Alt klasör yolu üretir: `INBOX` + `Arşiv` → `INBOX.Arşiv`
  String childPath(String childName) =>
      path.isEmpty ? childName : '$path$delimiter$childName';

  bool get isVirtual => specialUse == SpecialUse.custom && path.isEmpty;
}
