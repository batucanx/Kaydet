import 'dart:async';

import 'package:drift/drift.dart';

import '../../core/avatar.dart';
import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../database/app_database.dart';
import '../services/imap_service.dart';
import '../services/secure_store.dart';
import '../services/smtp_service.dart';
import 'mail_connection.dart';

/// Giriş ekranından gelen ham ayarlar.
class SignInRequest {
  const SignInRequest({
    required this.email,
    required this.password,
    required this.imapHost,
    required this.imapPort,
    required this.imapSecurity,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSecurity,
    this.username,
    this.displayName,
  });

  final String email;
  final String password;
  final String imapHost;
  final int imapPort;
  final SocketSecurity imapSecurity;
  final String smtpHost;
  final int smtpPort;
  final SocketSecurity smtpSecurity;
  final String? username;
  final String? displayName;

  String get effectiveUsername =>
      (username != null && username!.trim().isNotEmpty)
      ? username!.trim()
      : email.trim();
}

/// Hesap oluşturma, doğrulama ve silme.
class AccountRepository {
  AccountRepository({
    required AppDatabase database,
    required SecureStore secureStore,
    required ImapService imapService,
    required SmtpService smtpService,
    required MailConnection connection,
  }) : _db = database,
       _secureStore = secureStore,
       _imap = imapService,
       _smtp = smtpService,
       _connection = connection;

  final AppDatabase _db;
  final SecureStore _secureStore;
  final ImapService _imap;
  final SmtpService _smtp;
  final MailConnection _connection;

  /// Çıkışta IMAP oturumunun kapanması için beklenen en uzun süre.
  static const Duration _disconnectTimeout = Duration(seconds: 5);

  Stream<AccountRow?> watchActiveAccount() => _db.watchActiveAccount();
  Future<AccountRow?> activeAccount() => _db.activeAccount();

  /// Hesap değiştirici listesi — cihazdaki tüm hesaplar, tek seferde biri
  /// etkin olur. Birleşik gelen kutusu değil: eM Client'ın hesap listesine
  /// benzer ama her zaman tek bir hesap görüntülenir.
  Stream<List<AccountRow>> watchAllAccounts() => _db.watchAllAccounts();

  /// Sunucu ayarlarını sınar ve hesabı kaydeder.
  ///
  /// IMAP ve SMTP ayrı ayrı denenir: yalnızca biri yanlışsa kullanıcı hangi
  /// tarafın hatalı olduğunu bilir. Şifre veritabanına değil, güvenli
  /// depolamaya (Android Keystore) yazılır.
  Future<Result<int>> signIn(SignInRequest request) async {
    final email = request.email.trim();
    if (!EmailAddress.isValidEmail(email)) {
      return const Err(AuthFailure(detail: 'geçersiz e-posta adresi'));
    }
    if (request.password.isEmpty) {
      return const Err(AuthFailure(detail: 'şifre boş'));
    }

    // 1. IMAP doğrulaması
    final imapResult = await _imap.connect(
      MailServerConfig(
        host: request.imapHost.trim(),
        port: request.imapPort,
        security: request.imapSecurity,
        username: request.effectiveUsername,
        credential: PasswordCredential(request.password),
      ),
    );
    if (imapResult is Err<ServerCapabilities>) {
      await _imap.disconnect();
      return Err(imapResult.failure);
    }
    await _imap.disconnect();

    // 2. SMTP doğrulaması
    final smtpResult = await _smtp.verify(
      MailServerConfig(
        host: request.smtpHost.trim(),
        port: request.smtpPort,
        security: request.smtpSecurity,
        username: request.effectiveUsername,
        credential: PasswordCredential(request.password),
      ),
    );
    if (smtpResult is Err<void>) {
      final failure = smtpResult.failure;
      return Err(
        failure is AuthFailure
            ? AuthFailure(detail: 'SMTP: ${failure.detail}')
            : failure,
      );
    }

    // 3. Kayıt
    final displayName = (request.displayName?.trim().isNotEmpty ?? false)
        ? request.displayName!.trim()
        : displayNameFromEmail(email);

    return _persistAccount(
      email: email,
      username: request.effectiveUsername,
      displayName: displayName,
      imapHost: request.imapHost.trim(),
      imapPort: request.imapPort,
      imapSecurity: request.imapSecurity,
      smtpHost: request.smtpHost.trim(),
      smtpPort: request.smtpPort,
      smtpSecurity: request.smtpSecurity,
      writeCredential: (accountId) =>
          _secureStore.writePassword(accountId, request.password),
    );
  }

  /// Hesabı oluşturur/günceller, kimlik bilgisini [writeCredential] ile
  /// güvenli depoya yazar ve hesabı etkinleştirir.
  ///
  /// Hesap önce pasif yazılır. `isActive` true olur olmaz kök ekran
  /// uygulamaya geçer ve eşitleme başlar; kimlik bilgisi o an henüz güvenli
  /// depoda yoksa bağlantı katmanı "kayıtlı şifre/oturum yok" diye kimlik
  /// hatası döner ve kullanıcı giriş yaptığı hâlde hatalı bir uyarı görür.
  Future<Result<int>> _persistAccount({
    required String email,
    required String username,
    required String displayName,
    required String imapHost,
    required int imapPort,
    required SocketSecurity imapSecurity,
    required String smtpHost,
    required int smtpPort,
    required SocketSecurity smtpSecurity,
    required Future<void> Function(int accountId) writeCredential,
  }) async {
    final existing = await (_db.select(
      _db.accounts,
    )..where((a) => a.email.equals(email))).getSingleOrNull();

    final companion = AccountsCompanion(
      email: Value(email),
      username: Value(username),
      displayName: Value(displayName),
      imapHost: Value(imapHost),
      imapPort: Value(imapPort),
      imapSecurity: Value(imapSecurity),
      smtpHost: Value(smtpHost),
      smtpPort: Value(smtpPort),
      smtpSecurity: Value(smtpSecurity),
      colorSeed: Value(AvatarHash.hash32(email)),
      isActive: const Value(false),
    );

    final int accountId;
    if (existing != null) {
      await _db.updateAccountFields(existing.id, companion);
      accountId = existing.id;
    } else {
      accountId = await _db.insertAccount(companion);
      await _seedDefaultLabels(accountId);
      await _seedDefaultSignature(accountId, displayName);
    }

    try {
      await writeCredential(accountId);
    } on Object catch (error) {
      // Kimlik bilgisi saklanamadıysa hesap yarım kalmaz: yeni kayıt geri
      // alınır, kullanıcı giriş ekranında kalır ve nedenini görür.
      if (existing == null) await _db.wipeAccount(accountId);
      return Err(StorageFailure(detail: '$error'));
    }

    // Kimlik bilgisi yerinde; bu hesap etkinleşir. Tek işlemde yapılır ki
    // aradaki hiçbir hesabın etkin olmadığı an dışarıya sızmasın (bkz.
    // `AppDatabase.activateAccount`).
    await _db.activateAccount(accountId);
    return Ok(accountId);
  }

  /// Hesaplar arasında geçiş yapar: hedef etkinleşir, diğerleri pasifleşir.
  ///
  /// Etkinleştirme ÖNCE, ağ bağlantısı kapatma SONRA yapılır. Arayüzün tümü
  /// (`accountIdProvider` ve ona bağlı klasör/liste akışları) bu satırın
  /// tamamlanmasını bekler; eski sırada burası önce eski IMAP soketinin
  /// ağdan kapanmasını (`_disconnectTimeout`'a kadar) beklediği için hesap
  /// değiştirme Outlook'un aksine gözle görülür biçimde donuyordu — yeni
  /// hesabın verisi zaten yerelde olsa bile ekran hiçbir şey göstermeden
  /// bekliyordu. Şimdi yerel etkinleştirme anında olur, eski bağlantının
  /// kapanması arka planda sessizce sürer (`EnoughMailImapService`'in kendi
  /// kilidi `connect`/`disconnect`'i zaten sıraya koyduğundan, bu arada
  /// başlayacak yeni senkronizasyonun bağlanma çağrısıyla çakışmaz).
  ///
  /// Etkinleştirme tek işlemde yapılır (bkz. `AppDatabase.activateAccount`)
  /// — aksi hâlde aradaki "hiçbir hesap etkin değil" anı uygulama kökünü
  /// anlık olarak Giriş ekranına düşürür.
  Future<void> switchAccount(int accountId) async {
    await _db.activateAccount(accountId);
    unawaited(_disconnectPrevious());
  }

  Future<void> _disconnectPrevious() async {
    try {
      await _connection.disconnect().timeout(_disconnectTimeout);
    } on Object catch (_) {
      // Bağlantı kapanmasa da sorun değil; yeni hesap zaten etkin.
    }
  }

  Future<void> _seedDefaultLabels(int accountId) async {
    const defaults = [
      ('İş', 10),
      ('Kişisel', 6),
      ('Tasarım', 12),
      ('Finans', 3),
    ];
    for (final (name, tone) in defaults) {
      await _db.insertLabel(
        LabelsCompanion.insert(
          accountId: accountId,
          name: name,
          toneIndex: Value(tone),
        ),
      );
    }
  }

  /// Yeni etiket oluşturur (ad zaten varsa tonunu günceller).
  Future<void> createLabel({
    required int accountId,
    required String name,
    required int toneIndex,
  }) => _db.insertLabel(
    LabelsCompanion.insert(
      accountId: accountId,
      name: name,
      toneIndex: Value(toneIndex),
    ),
  );

  Future<void> deleteLabel(int labelId) => _db.deleteLabel(labelId);

  // --------------------------------------------------------------- klasörler

  /// Yeni kullanıcı klasörü oluşturur: önce sunucuda, başarılıysa yerelde —
  /// `_resolveTargetPath`'in Arşiv'i otomatik oluşturduğu desenin aynısı.
  ///
  /// [parentMailboxId] verilmezse klasör Gelen Kutusu'nun bir alt klasörü
  /// olarak açılır (üst düzey "Klasör Oluştur" — bkz.
  /// `FolderManagementScreen`); verilirse o klasörün alt klasörü olur
  /// ("Yeni Alt Klasör" — bkz. `_FolderManagementTile`'ın bağlam menüsü).
  ///
  /// Ad benzersizliği kasıtlı olarak HESAP GENELİNDE kontrol edilir
  /// (yalnızca kardeşler arasında değil) — üst düzey oluşturma zaten hep
  /// böyleydi; alt klasörler eklenince de aynı, tutarlı kural korunur.
  Future<Result<MailboxRow>> createFolder({
    required int accountId,
    required String name,
    int? parentMailboxId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const Err(StorageFailure(detail: 'klasör adı boş'));
    }

    final existing = await _db.mailboxesOf(accountId);
    final normalized = trLower(trimmed);
    if (existing.any((m) => trLower(m.name) == normalized)) {
      return const Err(DuplicateFolderFailure());
    }

    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final parent = parentMailboxId == null
        ? existing.where((m) => m.specialUse == SpecialUse.inbox).firstOrNull
        : existing.where((m) => m.id == parentMailboxId).firstOrNull;
    final path = parent == null ? trimmed : parent.childPath(trimmed);
    final created = await _connection.imap.createMailbox(path);
    if (created is Err<void>) return Err(created.failure);

    final nextOrder = existing.isEmpty
        ? 0
        : existing.map((m) => m.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
    final id = await _db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: path,
        name: trimmed,
        delimiter: Value(parent?.delimiter ?? '.'),
        sortOrder: Value(nextOrder),
      ),
    );
    final row = await _db.mailboxById(id);
    return row == null ? const Err(StorageFailure()) : Ok(row);
  }

  /// Klasörü Sık Kullanılanlar'a ekler/çıkarır — yalnızca yerel bir tercih,
  /// sunucuya hiç gönderilmez (bkz. `Mailboxes.isFavorite`).
  Future<void> setFolderFavorite(int mailboxId, bool value) =>
      _db.setMailboxFavorite(mailboxId, value);

  /// Klasörleri [orderedIds] sırasına göre kalıcı olarak yeniden sıralar.
  ///
  /// [orderedIds] hesabın TÜM yönetilebilir klasör kimlikleridir —
  /// sürüklenen bölüm Sık Kullanılanlar'ın bir alt kümesiyse bile
  /// (`FolderManagementScreen`), ekran önce tam listeyi bu alt kümenin yeni
  /// sırasına göre birleştirir; buraya her zaman eksiksiz sıralı bir liste
  /// gelir. Salt yerel bir tercihtir (bkz. `AppDatabase.upsertMailbox` —
  /// sunucu eşitlemesi bu sütuna dokunmaz).
  Future<void> reorderFolders(List<int> orderedIds) =>
      _db.reorderMailboxes(orderedIds);

  /// Klasörü yeniden adlandırır (aynı üst klasör, yeni son bileşen).
  ///
  /// Sistem klasörleri (Gelen Kutusu, Gönderilenler, …) korunur —
  /// `specialUse != custom` ise reddedilir. Sunucudaki `RENAME` başarılıysa
  /// yerelde `renameMailboxTree` çağrılır: id korunur, alt klasörler de
  /// (varsa) sunucuyla birlikte taşınmış sayılır — bkz. o metodun belgesi.
  Future<Result<void>> renameFolder({
    required int accountId,
    required int mailboxId,
    required String newName,
  }) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return const Err(StorageFailure(detail: 'klasör adı boş'));
    }

    final mailbox = await _db.mailboxById(mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());
    if (mailbox.specialUse != SpecialUse.custom) {
      return const Err(SystemFolderProtectedFailure());
    }
    if (trimmed == mailbox.name) return okVoid;

    final siblings = await _db.mailboxesOf(accountId);
    final normalized = trLower(trimmed);
    if (siblings.any(
      (m) => m.id != mailboxId && trLower(m.name) == normalized,
    )) {
      return const Err(DuplicateFolderFailure());
    }

    final delimiter = mailbox.delimiter;
    final parentEnd = mailbox.path.lastIndexOf(delimiter);
    final newPath = parentEnd == -1
        ? trimmed
        : '${mailbox.path.substring(0, parentEnd + delimiter.length)}$trimmed';

    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final renamed = await _connection.imap.renameMailbox(
      path: mailbox.path,
      encodedPath: mailbox.encodedPath,
      delimiter: delimiter,
      newPath: newPath,
    );
    if (renamed is Err<void>) return Err(renamed.failure);

    await _db.renameMailboxTree(
      mailboxId: mailboxId,
      oldPath: mailbox.path,
      newPath: newPath,
      newName: trimmed,
      delimiter: delimiter,
    );
    return okVoid;
  }

  /// Klasörü başka bir klasörün altına taşır (aynı son bileşen, yeni üst
  /// klasör) — [newParentId] `null` ise kök düzeye (Gelen Kutusu ile aynı
  /// seviyeye) taşınır. Mekanizma [renameFolder] ile birebir aynıdır (IMAP
  /// `RENAME`); tek fark hedef yolun nasıl hesaplandığıdır.
  Future<Result<void>> moveFolder({
    required int accountId,
    required int mailboxId,
    required int? newParentId,
  }) async {
    final mailbox = await _db.mailboxById(mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());
    if (mailbox.specialUse != SpecialUse.custom) {
      return const Err(SystemFolderProtectedFailure());
    }

    final delimiter = mailbox.delimiter;
    final leaf = FolderMapping.leafName(mailbox.path, delimiter);
    final ownSubtreePrefix = '${mailbox.path}$delimiter';

    String newPath;
    if (newParentId == null) {
      newPath = leaf;
    } else {
      if (newParentId == mailboxId) {
        return const Err(InvalidFolderMoveFailure());
      }
      final parent = await _db.mailboxById(newParentId);
      if (parent == null) return const Err(MailboxNotFoundFailure());
      if (parent.path.startsWith(ownSubtreePrefix)) {
        return const Err(InvalidFolderMoveFailure());
      }
      newPath = parent.childPath(leaf);
    }
    if (newPath == mailbox.path) return okVoid;

    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final renamed = await _connection.imap.renameMailbox(
      path: mailbox.path,
      encodedPath: mailbox.encodedPath,
      delimiter: delimiter,
      newPath: newPath,
    );
    if (renamed is Err<void>) return Err(renamed.failure);

    await _db.renameMailboxTree(
      mailboxId: mailboxId,
      oldPath: mailbox.path,
      newPath: newPath,
      newName: mailbox.name,
      delimiter: delimiter,
    );
    return okVoid;
  }

  /// Klasörü kalıcı olarak siler. Sistem klasörleri ve alt klasörü olan
  /// klasörler korunur — RFC 3501 `DELETE`nin alt klasörleri ne yapacağı
  /// sunucudan sunucuya değiştiğinden, belirsiz bir sunucu davranışına
  /// güvenmek yerine yerelde açıkça reddedilir.
  Future<Result<void>> deleteFolder({
    required int accountId,
    required int mailboxId,
  }) async {
    final mailbox = await _db.mailboxById(mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());
    if (mailbox.specialUse != SpecialUse.custom) {
      return const Err(SystemFolderProtectedFailure());
    }

    final siblings = await _db.mailboxesOf(accountId);
    final ownSubtreePrefix = '${mailbox.path}${mailbox.delimiter}';
    final hasChildren = siblings.any(
      (m) => m.id != mailboxId && m.path.startsWith(ownSubtreePrefix),
    );
    if (hasChildren) return const Err(FolderHasChildrenFailure());

    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final deleted = await _connection.imap.deleteMailbox(
      path: mailbox.path,
      encodedPath: mailbox.encodedPath,
      delimiter: mailbox.delimiter,
    );
    if (deleted is Err<void>) return Err(deleted.failure);

    await _db.deleteMailboxWithMessages(mailboxId);
    return okVoid;
  }

  Future<void> _seedDefaultSignature(int accountId, String displayName) =>
      _db.insertSignature(
        SignaturesCompanion.insert(
          accountId: accountId,
          name: 'İmza 1',
          body: Value('\n\n--\n$displayName\nKaydet ile gönderildi'),
          isDefault: const Value(true),
        ),
      );

  /// Yeni imza oluşturur. Hesabın ilk imzasıysa otomatik varsayılan olur —
  /// aksi hâlde kullanıcı bir imza ekleyip onu hiç varsayılan yapmadan
  /// yazma ekranına girerse hiçbir imza otomatik eklenmez, bu şaşırtıcı olur.
  Future<void> createSignature({
    required int accountId,
    required String name,
    required String body,
  }) async {
    final hasAny = (await _db.signaturesOf(accountId)).isNotEmpty;
    await _db.insertSignature(
      SignaturesCompanion.insert(
        accountId: accountId,
        name: name,
        body: Value(body),
        isDefault: Value(!hasAny),
      ),
    );
  }

  Future<void> updateSignatureContent({
    required int signatureId,
    required String name,
    required String body,
  }) => _db.updateSignatureRow(
    signatureId,
    SignaturesCompanion(name: Value(name), body: Value(body)),
  );

  Future<void> deleteSignature(int signatureId) =>
      _db.deleteSignature(signatureId);

  Future<void> setDefaultSignature(int accountId, int signatureId) =>
      _db.setDefaultSignature(accountId, signatureId);

  /// Kişiyi elle ekler/günceller — otomatik yakalamayla aynı yol
  /// (bkz. `AppDatabase.upsertContact`), Kişiler sekmesinin "+" düğmesi
  /// için.
  Future<void> createContact({
    required int accountId,
    required String email,
    required String name,
  }) => _db.upsertContact(accountId: accountId, email: email, name: name);

  Future<void> deleteContact(int contactId) => _db.deleteContact(contactId);

  Future<void> updateDisplayName(int accountId, String displayName) =>
      _db.updateAccountFields(
        accountId,
        AccountsCompanion(displayName: Value(displayName)),
      );

  /// Hesaptan çıkış: bağlantı kapanır, şifre ve tüm yerel veri silinir.
  ///
  /// Ağ tarafında ne olursa olsun çıkış tamamlanır. Sunucu yanıt vermezken
  /// soketin kapanmasını beklemek kullanıcıyı hesabın içinde kilitler:
  /// bağlantı en fazla [_disconnectTimeout] kadar beklenir, ardından yerel
  /// veriler her hâlde silinir.
  ///
  /// Cihazda başka hesap kaldıysa çıkış uygulamayı Giriş ekranına düşürmez:
  /// kalan hesaplardan biri (en eski eklenen) otomatik etkinleşir. Silinen
  /// hesap o an etkin değilse paylaşılan IMAP bağlantısına dokunulmaz —
  /// aksi hâlde etkin hesabın canlı oturumu, alakasız bir hesap listeden
  /// kaldırılırken boşuna kapanır.
  Future<void> signOut(int accountId) async {
    final isActiveAccount = (await _db.activeAccount())?.id == accountId;

    if (isActiveAccount) {
      try {
        await _connection.disconnect().timeout(_disconnectTimeout);
      } on Object catch (_) {
        // Bağlantı kapanmasa da çıkış sürmeli.
      }
    }
    try {
      await _secureStore.deletePassword(accountId);
    } on Object catch (_) {
      // Keystore'a erişilemese bile hesap kaydı silinir; kimlik bilgisi
      // sahipsiz kalır, hesap olmadan kullanılamaz.
    }
    // Silme ve yeni hesabı etkinleştirme tek işlemde yapılır: aksi hâlde
    // aradaki "hiçbir hesap etkin değil" anı uygulama kökünü anlık olarak
    // Giriş ekranına düşürür (bkz. `AppDatabase.activateAccount`).
    await _db.transaction(() async {
      await _db.wipeAccount(accountId);
      if (!isActiveAccount) return;
      final remaining = await _db.allAccounts();
      if (remaining.isNotEmpty) {
        await _db.updateAccountFields(
          remaining.first.id,
          const AccountsCompanion(isActive: Value(true)),
        );
      }
    });
  }

  /// Şifre yeniden istenince günceller (kimlik doğrulama hatası sonrası).
  Future<void> updatePassword(int accountId, String password) =>
      _secureStore.writePassword(accountId, password);
}
