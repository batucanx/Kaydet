import 'dart:async';

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
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
    bool keepAlive = true,
  })  : _db = database,
        _secureStore = secureStore,
        _imap = imapService,
        _keepAliveEnabled = keepAlive;

  final AppDatabase _db;
  final SecureStore _secureStore;
  final ImapService _imap;

  /// `false` ise 4 dakikalık canlılık zamanlayıcısı kurulmaz. Sürekli IDLE
  /// dinleyen bağlantılar (bkz. `AccountWatcher`) kendi döngüleriyle canlılığı
  /// denetler ve dışarıdan bir NOOP'a ihtiyaç duymaz.
  final bool _keepAliveEnabled;

  Timer? _keepAlive;
  int? _accountId;
  ServerCapabilities _capabilities = ServerCapabilities.unknown;
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
        _startKeepAlive();
        return okVoid;
      },
      (failure) {
        _stopKeepAlive();
        return Err(failure);
      },
    );
  }

  void _startKeepAlive() {
    _stopKeepAlive();
    if (!_keepAliveEnabled) return;
    // Sunucular genelde 30 dakikada boş oturumu düşürür; 4 dakika güvenli.
    _keepAlive = Timer.periodic(
      const Duration(minutes: 4),
      (_) => keepAliveTick(),
    );
  }

  /// Canlılık denetiminin tek turu (4 dakikada bir çalışır).
  ///
  /// IDLE sürerken NOOP GÖNDERİLMEZ: her komut sürmekte olan IDLE'ı bitirir
  /// (bkz. `EnoughMailImapService._guard`) ve NOOP'tan sonra IDLE'ı yeniden
  /// başlatan yoktu — bu yüzden anlık güncellemeler bağlantı kurulduktan en
  /// fazla 4 dakika sonra sessizce duruyordu. IDLE zaten bir canlılık
  /// mekanizmasıdır: `SyncController` onu 25 dakikada bir (RFC 2177 sınırı 29)
  /// yeniler ve NOOP'un yaptığı işi görür.
  Future<void> keepAliveTick() async {
    if (!_imap.isConnected || _imap.isIdling) return;
    await _imap.noop();
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

  /// Hesabın kimlik bilgisini güvenli depodan üretir.
  Future<Result<MailCredential>> _credentialFor(AccountRow account) async {
    final password = await _secureStore.readPassword(account.id);
    if (password == null || password.isEmpty) {
      return const Err(AuthFailure(detail: 'kayıtlı şifre yok'));
    }
    return Ok(PasswordCredential(password));
  }
}

/// Bir hesabın klasör yolu yardımcıları.
extension MailboxPathHelpers on MailboxRow {
  /// Alt klasör yolu üretir: `INBOX` + `Arşiv` → `INBOX.Arşiv`
  String childPath(String childName) =>
      path.isEmpty ? childName : '$path$delimiter$childName';

  bool get isVirtual => specialUse == SpecialUse.custom && path.isEmpty;
}
