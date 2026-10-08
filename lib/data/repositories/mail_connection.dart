import 'dart:async';

import 'package:synchronized/synchronized.dart';

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
///
/// **Mantıksal işlemler tek tek serileştirilir.** IMAP'te `SELECT` bağlantı
/// başına TEK klasör seçer ve UID'ler klasöre özgüdür: `SELECT` ile onu izleyen
/// `STORE`/`EXPUNGE`/`FETCH` arasına başka bir işlem girip başka bir klasör
/// (ya da başka bir hesap) seçerse komut yanlış klasörde çalışır ve sunucu
/// yine de "OK" döner. [ImapService]'in kendi komut başına kilidi bunu
/// engelleyemez; bu yüzden birden çok komuttan oluşan her mantıksal işlem
/// ([exclusive] / [locked]) bu sınıfın kilidi altında baştan sona çalışır.
/// Kilit yeniden girişli DEĞİLDİR: [exclusive]/[locked]/[ensureConnected]
/// çağrılan bir işlemin içinden tekrar çağrılamaz (kilitlenir).
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

  /// Mantıksal IMAP işlemlerini sıraya dizer (bkz. sınıf açıklaması).
  final Lock _lock = Lock();

  Timer? _keepAlive;

  /// Şu an bağlı olan hesap. YALNIZCA bağlantı gerçekten kurulduktan sonra
  /// yazılır: bağlanma sürerken başka bir çağıran, hâlâ eski hesaba ait olan
  /// soketi yeni hesabın bağlantısı sanıp onunla işlem yapamaz.
  int? _connectedAccountId;

  ServerCapabilities _capabilities = ServerCapabilities.unknown;

  ImapService get imap => _imap;
  ServerCapabilities get capabilities => _capabilities;
  bool get isConnected => _imap.isConnected;
  Stream<void> get serverChanges => _imap.serverChanges;

  /// Bağlantı şu an tam olarak [accountId] hesabına mı ait?
  bool isConnectedTo(int accountId) =>
      _imap.isConnected && _connectedAccountId == accountId;

  /// Bağlantının hazır olduğundan emin olur.
  ///
  /// Kilidi alır: başka bir işlem sürerken hesap değiştirmek o işlemin soketini
  /// altından çekerdi, bu yüzden sıra beklenir. Zaten bir [exclusive] ya da
  /// [locked] işleminin İÇİNDEN çağrılmamalıdır.
  Future<Result<void>> ensureConnected(int accountId) =>
      _lock.synchronized(() => _ensureConnectedUnlocked(accountId));

  /// [accountId] hesabına bağlanıp [action]'ı tek bir mantıksal işlem olarak,
  /// başka hiçbir IMAP işlemi araya giremeden çalıştırır.
  ///
  /// [action] içinde birden çok komut (SELECT → FETCH gibi) güvenle
  /// kullanılabilir; `ensureConnected`/`exclusive`/`locked` çağrılmamalıdır.
  Future<Result<R>> exclusive<R>(
    int accountId,
    Future<Result<R>> Function() action,
  ) => _lock.synchronized(() async {
    final connected = await _ensureConnectedUnlocked(accountId);
    if (connected is Err<void>) return Err<R>(connected.failure);
    return action();
  });

  /// Bağlantı kurmadan [action]'ı işlem kilidi altında çalıştırır. Bağlantının
  /// beklenen hesaba ait olduğunu doğrulamak [action]'ın işidir
  /// (bkz. [isConnectedTo]).
  Future<T> locked<T>(Future<T> Function() action) =>
      _lock.synchronized(action);

  /// Klasörü seçer ve yerel UID'lerin hâlâ geçerli olduğunu doğrular.
  ///
  /// Sunucunun UIDVALIDITY değeri yerelde kayıtlı olandan farklıysa yerel
  /// UID'ler artık başka iletileri gösterir; onlarla `FETCH`/`STORE` yapmak
  /// YANLIŞ iletiyi okur ya da değiştirir. Bu durumda
  /// [UidValidityChangedFailure] döner; klasör bir sonraki eşitlemede baştan
  /// indirilir. Yalnızca [exclusive]/[locked] içinde çağrılmalıdır.
  Future<Result<MailboxState>> selectVerified(
    MailboxRow mailbox, {
    bool enableCondStore = false,
  }) async {
    final selected = await _imap.selectMailbox(
      mailbox.path,
      enableCondStore: enableCondStore,
    );
    if (selected is Err<MailboxState>) return selected;
    final state = (selected as Ok<MailboxState>).value;
    final known = mailbox.uidValidity;
    if (known != null && state.uidValidity != 0 && known != state.uidValidity) {
      return Err(
        UidValidityChangedFailure(
          mailboxPath: mailbox.path,
          oldValue: known,
          newValue: state.uidValidity,
        ),
      );
    }
    return selected;
  }

  Future<Result<void>> _ensureConnectedUnlocked(int accountId) async {
    if (_imap.isConnected && _connectedAccountId == accountId) return okVoid;

    // Farklı hesaba geçiş ya da kopmuş bağlantı: bağlanma bitene dek hiçbir
    // hesap "bağlı" sayılmaz.
    _connectedAccountId = null;
    final result = await _connect(accountId);
    if (result.isOk) _connectedAccountId = accountId;
    return result;
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

  /// Arka plandan dönüşte bağlantının gerçekten canlı olduğunu doğrular.
  ///
  /// iOS arka plandaki soketi sessizce öldürür ama `isConnected` bayrağı
  /// `true` kalır; ilk komut ölü soket üzerinde 30 sn'lik zaman aşımına kadar
  /// takılırdı. Kısa süreli bir NOOP bunu saniyeler içinde yakalar ve soketi
  /// kapatır; sonraki işlem (`exclusive`) taze bağlantı kurar.
  Future<void> revalidate(
    int accountId, {
    Duration timeout = const Duration(seconds: 3),
  }) => _lock.synchronized(() async {
    if (!isConnectedTo(accountId)) return;
    final result = await _imap.noop(timeout: timeout);
    if (result is Err<void>) await disconnect();
  });

  void _stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  /// Bağlantıyı kapatır. Sürmekte olan bir işlemi BEKLEMEZ: çıkış yapan
  /// kullanıcının sunucu yanıt vermediği için kilitlenmemesi gerekir; süren
  /// işlem bağlantı hatasıyla biter.
  Future<void> disconnect() async {
    _stopKeepAlive();
    _connectedAccountId = null;
    _capabilities = ServerCapabilities.unknown;
    await _imap.disconnect();
  }

  /// Bağlantı hâlâ [accountId] hesabına aitse kapatır; başka bir hesaba
  /// geçilmişse HİÇ dokunmaz.
  ///
  /// Hesap değiştirilirken eski hesabın oturumu arka planda kapatılır; bu
  /// kapatma, yeni hesabın bağlantısı kurulduktan SONRA çalışırsa onu da
  /// kapatırdı. Kontrol işlem kilidi altında yapılır (bağlantılar yalnızca bu
  /// kilit altında kurulur), bu yüzden araya yeni bir bağlantı giremez.
  Future<void> disconnectAccount(int accountId) => _lock.synchronized(() async {
    if (_connectedAccountId != accountId) return;
    await disconnect();
  });

  /// Hesabın IMAP ayarlarını güvenli depodaki kimlik bilgisiyle birleştirir (bağlantı kurmaz).
  /// ManageSieve gibi aynı sunucudaki yan hizmetler kullanır.
  Future<MailServerConfig?> imapConfig(int accountId) async {
    final account = await _db.accountById(accountId);
    if (account == null) return null;
    final credentialResult = await _credentialFor(account);
    if (credentialResult is Err<MailCredential>) return null;
    return MailServerConfig(
      host: account.imapHost,
      port: account.imapPort,
      security: account.imapSecurity,
      username: account.username,
      credential: (credentialResult as Ok<MailCredential>).value,
    );
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
    final String? password;
    try {
      password = await _secureStore.readPassword(account.id);
    } on Object catch (error) {
      // Keystore geçici olarak okunamadı (ör. yeniden başlatma sonrası).
      // Bu bir kimlik hatası DEĞİL: kullanıcıyı yeniden girişe yönlendirmez,
      // depoya da dokunmaz; bir sonraki denemede yeniden okunur.
      return Err(StorageFailure(detail: '$error'));
    }
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
