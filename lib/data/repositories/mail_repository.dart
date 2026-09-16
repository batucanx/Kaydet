import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../../domain/use_cases/text_extraction.dart';
import '../database/app_database.dart';
import '../database/tables.dart';
import '../services/smtp_service.dart';
import 'mail_connection.dart';
import 'sync_engine.dart';

/// Kullanıcı eylemleri, bekleyen işlem kuyruğu ve giden kutusu.
///
/// Her eylem önce yerel veritabanına yazılır (arayüz anında tepki verir),
/// sonra kuyruğa alınır. Ağ uygun olduğunda kuyruk sunucuya işlenir.
/// Sunucu reddederse bir sonraki eşitleme yerel durumu düzeltir.
class MailRepository {
  MailRepository({
    required AppDatabase database,
    required MailConnection connection,
    required SyncEngine syncEngine,
    required SmtpService smtpService,
  }) : _db = database,
       _connection = connection,
       _sync = syncEngine,
       _smtp = smtpService;

  final AppDatabase _db;
  final MailConnection _connection;
  final SyncEngine _sync;
  final SmtpService _smtp;

  AppDatabase get database => _db;
  SyncEngine get syncEngine => _sync;
  MailConnection get connection => _connection;

  /// En fazla deneme sayısı; sonrasında işlem kalıcı hata sayılır.
  static const int maxAttempts = 5;

  bool _processing = false;

  /// Kuyruğu arka planda hemen işlemeye çalışır.
  ///
  /// Kullanıcı bir iletiyi sildiğinde veya okundu işaretlediğinde işlem
  /// sunucuya ANINDA gitmelidir; bir sonraki eşitlemeyi beklemek, başka
  /// cihazdan bakan kullanıcının eski durumu görmesi demektir. Ağ yoksa
  /// işlem kuyrukta kalır ve bağlantı gelince yeniden denenir.
  void kickQueue(int accountId) {
    if (_processing) return;
    unawaited(processQueue(accountId));
  }

  // ------------------------------------------------------------- okundu

  /// Okundu / okunmadı işaretler.
  Future<void> setSeen(List<int> messageIds, bool seen) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    await _db.updateMessages(
      messageIds,
      MessagesCompanion(isSeen: Value(seen)),
    );
    await _enqueueByMailbox(
      rows,
      seen ? PendingOpType.markSeen : PendingOpType.markUnseen,
    );
    kickQueue(rows.first.accountId);
  }

  /// Sabitler / sabitlemeyi kaldırır (IMAP `\Flagged`).
  Future<void> setFlagged(List<int> messageIds, bool flagged) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    await _db.updateMessages(
      messageIds,
      MessagesCompanion(isFlagged: Value(flagged)),
    );
    await _enqueueByMailbox(
      rows,
      flagged ? PendingOpType.flag : PendingOpType.unflag,
    );
    kickQueue(rows.first.accountId);
  }

  // ------------------------------------------------------------- taşıma

  /// İletileri hedef klasöre taşır.
  ///
  /// Yerelde satır silinir: taşındıktan sonra iletinin hedef klasörde yeni
  /// bir UID'si olur, eski UID'yi taşımak yanlış iletiye işlem yapılmasına
  /// yol açar. Sunucu işlemi başarısız olursa kaynak klasörün bir sonraki
  /// eşitlemesi satırı geri getirir — sistem kendini onarır.
  Future<void> moveToMailbox({
    required List<int> messageIds,
    required SpecialUse target,
  }) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    final accountId = rows.first.accountId;
    final targetBox = await _db.mailboxBySpecialUse(accountId, target);

    // Yerel taslaklar sunucuya hiç gitmemiştir; doğrudan silinir.
    final localOnly = rows
        .where((r) => r.isLocalOnly)
        .map((r) => r.id)
        .toList();
    if (localOnly.isNotEmpty) await _db.deleteMessages(localOnly);

    final remote = rows.where((r) => !r.isLocalOnly && r.uid != null).toList();
    if (remote.isEmpty) return;

    await _enqueueByMailbox(
      remote,
      PendingOpType.move,
      extra: {'targetPath': targetBox?.path, 'targetSpecialUse': target.index},
    );
    await _db.deleteMessages(remote.map((r) => r.id).toList());
    kickQueue(accountId);
  }

  /// Siler: normal klasörde Çöp Kutusu'na taşır, Çöp Kutusu'nda kalıcı siler.
  Future<void> deleteMessages(List<int> messageIds) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    final byMailbox = <int, List<MessageRow>>{};
    for (final row in rows) {
      byMailbox.putIfAbsent(row.mailboxId, () => []).add(row);
    }

    for (final entry in byMailbox.entries) {
      final mailbox = await _db.mailboxById(entry.key);
      final permanent =
          mailbox != null &&
          FolderMapping.deleteIsPermanent(mailbox.specialUse);
      if (permanent) {
        await deletePermanently(entry.value.map((r) => r.id).toList());
      } else {
        await moveToMailbox(
          messageIds: entry.value.map((r) => r.id).toList(),
          target: SpecialUse.trash,
        );
      }
    }
  }

  /// Kalıcı siler — geri dönüşü yoktur, çağıran onay almalıdır.
  Future<void> deletePermanently(List<int> messageIds) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    final remote = rows.where((r) => !r.isLocalOnly && r.uid != null).toList();
    if (remote.isNotEmpty) {
      await _enqueueByMailbox(remote, PendingOpType.deletePermanently);
    }
    await _db.deleteMessages(rows.map((r) => r.id).toList());
    kickQueue(rows.first.accountId);
  }

  Future<void> archive(List<int> messageIds) =>
      moveToMailbox(messageIds: messageIds, target: SpecialUse.archive);

  Future<void> markSpam(List<int> messageIds) =>
      moveToMailbox(messageIds: messageIds, target: SpecialUse.junk);

  /// Çöp kutusunu boşaltır.
  Future<void> emptyTrash(int accountId) async {
    final trash = await _db.mailboxBySpecialUse(accountId, SpecialUse.trash);
    if (trash == null) return;
    final rows = await (_db.select(
      _db.messages,
    )..where((m) => m.mailboxId.equals(trash.id))).get();
    await deletePermanently(rows.map((r) => r.id).toList());
  }

  // ------------------------------------------------------------ etiketler

  Future<void> setLabel({
    required List<int> messageIds,
    required String labelName,
    required bool add,
  }) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    for (final row in rows) {
      final labels = _decodeLabels(row.labelsJson);
      if (add) {
        if (labels.contains(labelName)) continue;
        labels.add(labelName);
      } else {
        if (!labels.remove(labelName)) continue;
      }
      await _db.updateMessage(
        row.id,
        MessagesCompanion(labelsJson: Value(jsonEncode(labels))),
      );
    }

    final account = await _db.accountById(rows.first.accountId);
    // Sunucu özel anahtar kelime desteklemiyorsa etiket yalnızca yereldir.
    if (account?.supportsKeywords != true) return;

    await _enqueueByMailbox(
      rows.where((r) => r.uid != null).toList(),
      add ? PendingOpType.addKeyword : PendingOpType.removeKeyword,
      extra: {'keyword': _keywordFor(labelName)},
    );
    kickQueue(rows.first.accountId);
  }

  static String _keywordFor(String labelName) =>
      'kaydet_${foldForSearch(labelName).replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

  static List<String> _decodeLabels(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // Bozuk veri listeyi boşaltır, uygulamayı çökertmez.
    }
    return <String>[];
  }

  // -------------------------------------------------------------- gövde

  /// İletinin gövdesini gerekirse indirir.
  Future<Result<void>> ensureBody(int messageId) async {
    final row = await _db.messageById(messageId);
    if (row == null) return const Err(UnknownFailure(detail: 'ileti yok'));
    if (row.bodyFetchedAt != null) return okVoid;
    if (row.uid == null) return okVoid; // yerel taslak

    final mailbox = await _db.mailboxById(row.mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());

    final connected = await _connection.ensureConnected(row.accountId);
    if (connected is Err<void>) return connected;

    final selected = await _connection.imap.selectMailbox(mailbox.path);
    if (selected is Err<MailboxState>) return Err(selected.failure);

    final body = await _connection.imap.fetchBody(row.uid!);
    if (body is Err<FetchedBody>) return Err(body.failure);

    await _sync.storeBody(row, (body as Ok<FetchedBody>).value);
    return okVoid;
  }

  /// Ek dosyayı indirir ve cihazdaki yolunu döner.
  Future<Result<String>> downloadAttachment(int attachmentId) async {
    final attachment = await (_db.select(
      _db.attachments,
    )..where((a) => a.id.equals(attachmentId))).getSingleOrNull();
    if (attachment == null) {
      return const Err(UnknownFailure(detail: 'ek bulunamadı'));
    }
    final existing = attachment.localPath;
    if (existing != null && File(existing).existsSync()) return Ok(existing);

    final row = await _db.messageById(attachment.messageId);
    if (row?.uid == null) return const Err(UnknownFailure(detail: 'ileti yok'));

    final mailbox = await _db.mailboxById(row!.mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());

    final connected = await _connection.ensureConnected(row.accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final selected = await _connection.imap.selectMailbox(mailbox.path);
    if (selected is Err<MailboxState>) return Err(selected.failure);

    final data = await _connection.imap.fetchAttachment(
      row.uid!,
      attachment.partId,
    );
    if (data is Err) return Err((data as Err).failure);

    try {
      final dir = await getApplicationSupportDirectory();
      final folder = Directory(p.join(dir.path, 'ekler', '${row.id}'));
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final safeName = attachment.fileName.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
        '_',
      );
      final file = File(p.join(folder.path, safeName));
      await file.writeAsBytes((data as Ok).value);
      await _db.setAttachmentPath(attachmentId, file.path);
      return Ok(file.path);
    } on FileSystemException catch (error) {
      return Err(StorageFailure(detail: error.message));
    }
  }

  // ------------------------------------------------------ taslak & gönderim

  /// Taslağı yerel olarak kaydeder (otomatik kaydetme dahil).
  Future<int> saveDraft({
    required int accountId,
    int? draftId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String body,
    String? html,
    List<String> attachmentPaths = const [],
    int? replyToMessageId,
    String? inReplyTo,
    String? references,
  }) async {
    final drafts = await _db.mailboxBySpecialUse(accountId, SpecialUse.drafts);
    final account = await _db.accountById(accountId);
    final mailboxId =
        drafts?.id ??
        (await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox))?.id;
    if (mailboxId == null) return -1;

    final companion = MessagesCompanion(
      accountId: Value(accountId),
      mailboxId: Value(mailboxId),
      dateUtc: Value(DateTime.now().toUtc()),
      subject: Value(subject),
      subjectNormalized: Value(normalizeSubject(subject)),
      fromName: Value(account?.displayName ?? ''),
      fromEmail: Value(account?.email ?? ''),
      toAddrJson: Value(EmailAddress.encodeList(EmailAddress.parseInput(to))),
      ccJson: Value(EmailAddress.encodeList(EmailAddress.parseInput(cc))),
      bccJson: Value(EmailAddress.encodeList(EmailAddress.parseInput(bcc))),
      preview: Value(TextExtraction.buildPreview(body)),
      isSeen: const Value(true),
      isDraft: const Value(true),
      isLocalOnly: const Value(true),
      hasAttachments: Value(attachmentPaths.isNotEmpty),
      outboxState: const Value(OutboxState.none),
      replyToMessageId: Value(replyToMessageId),
      inReplyTo: Value(inReplyTo),
      referencesRaw: Value(references),
    );

    final int id;
    if (draftId != null && draftId > 0) {
      await _db.updateMessage(draftId, companion);
      id = draftId;
    } else {
      id = await _db.insertLocalMessage(companion);
    }

    await _db.upsertBody(messageId: id, plainText: body, html: html);
    await _syncDraftAttachments(id, attachmentPaths);
    return id;
  }

  Future<void> _syncDraftAttachments(int messageId, List<String> paths) async {
    final existing = await _db.attachmentsOf(messageId);
    for (final row in existing.where((a) => a.isOutgoing)) {
      if (!paths.contains(row.localPath)) {
        await _db.removeAttachment(row.id);
      }
    }
    final known = existing.map((a) => a.localPath).toSet();
    for (final path in paths) {
      if (known.contains(path)) continue;
      final file = File(path);
      await _db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: messageId,
          fileName: Value(p.basename(path)),
          sizeBytes: Value(file.existsSync() ? file.lengthSync() : 0),
          localPath: Value(path),
          isOutgoing: const Value(true),
          mimeType: Value(_guessMime(path)),
        ),
      );
    }
  }

  static String _guessMime(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.pdf' => 'application/pdf',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.txt' => 'text/plain',
      '.csv' => 'text/csv',
      '.zip' => 'application/zip',
      '.doc' => 'application/msword',
      '.docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.xls' => 'application/vnd.ms-excel',
      '.xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      _ => 'application/octet-stream',
    };
  }

  /// İletiyi gönderim kuyruğuna alır.
  ///
  /// Gönderim anında yapılmaz: önce yerel kayıt "Gönderiliyor" durumuna
  /// geçer, sonra kuyruk işlenir. Böylece ağ yokken yazılan ileti kaybolmaz.
  Future<int> queueSend({
    required int accountId,
    int? draftId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String body,
    String? html,
    List<String> attachmentPaths = const [],
    int? replyToMessageId,
    String? inReplyTo,
    String? references,
  }) async {
    final id = await saveDraft(
      accountId: accountId,
      draftId: draftId,
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      body: body,
      html: html,
      attachmentPaths: attachmentPaths,
      replyToMessageId: replyToMessageId,
      inReplyTo: inReplyTo,
      references: references,
    );
    if (id < 0) return id;

    // Gönderim kuyruğundaki ileti yerelde Gönderilenler'e taşınır: kullanıcı
    // "gönderdim" dedikten sonra iletisini Taslaklar'da değil, beklediği
    // yerde görür. Gerçekten gönderilince aynı satır sunucudaki kopyaya
    // bağlanır, kopya oluşmaz.
    final sentBox = await _db.mailboxBySpecialUse(accountId, SpecialUse.sent);
    await _db.updateMessage(
      id,
      MessagesCompanion(
        outboxState: const Value(OutboxState.queued),
        isDraft: const Value(false),
        outboxError: const Value(null),
        mailboxId: sentBox == null ? const Value.absent() : Value(sentBox.id),
      ),
    );

    await _db.enqueue(
      PendingOperationsCompanion.insert(
        accountId: accountId,
        type: PendingOpType.send,
        payloadJson: Value(jsonEncode({'messageId': id})),
      ),
    );
    return id;
  }

  // ------------------------------------------------------------ kuyruk

  /// Bekleyen işlemleri sunucuya uygular.
  ///
  /// Aynı anda yalnızca bir tur çalışır: iki tur aynı işlemi iki kez
  /// göndermemelidir (özellikle gönderim işlemleri için kritik).
  Future<void> processQueue(int accountId) async {
    if (_processing) return;
    _processing = true;
    try {
      final operations = await _db.dueOperations(accountId);
      if (operations.isEmpty) return;

      final connected = await _connection.ensureConnected(accountId);
      if (connected is Err<void>) return;

      for (final op in operations) {
        final result = await _execute(accountId, op);
        await result.fold(
          (_) => _db.completeOperation(op.id),
          (failure) => _handleFailure(op, failure),
        );
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _handleFailure(
    PendingOperationRow op,
    AppFailure failure,
  ) async {
    final attempt = op.attemptCount + 1;
    final permanent =
        (failure is ServerFailure && failure.isPermanent) ||
        failure is RecipientRejectedFailure ||
        attempt >= maxAttempts;

    // Geçici hatalarda gecikme: 30 sn, 5 dk, 30 dk, 2 sa.
    const delays = [
      Duration(seconds: 30),
      Duration(minutes: 5),
      Duration(minutes: 30),
      Duration(hours: 2),
    ];
    final delay = delays[(attempt - 1).clamp(0, delays.length - 1)];

    await _db.failOperation(
      op.id,
      error: failure.userMessage,
      attemptCount: attempt,
      nextAttemptAt: permanent ? null : DateTime.now().toUtc().add(delay),
      permanent: permanent,
    );

    if (op.type == PendingOpType.send && permanent) {
      final payload = _payloadOf(op);
      final messageId = payload['messageId'];
      if (messageId is int) {
        await _db.updateMessage(
          messageId,
          MessagesCompanion(
            outboxState: const Value(OutboxState.failed),
            outboxError: Value(failure.userMessage),
          ),
        );
      }
    }
  }

  Map<String, dynamic> _payloadOf(PendingOperationRow op) {
    try {
      final decoded = jsonDecode(op.payloadJson);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Bozuk yük boş kabul edilir.
    }
    return const {};
  }

  Future<Result<void>> _execute(int accountId, PendingOperationRow op) async {
    final payload = _payloadOf(op);
    final uids = (payload['uids'] as List?)?.whereType<int>().toList() ?? [];
    final mailboxPath = payload['mailboxPath'] as String?;

    Future<Result<void>> withMailbox(
      Future<Result<void>> Function() action,
    ) async {
      if (mailboxPath == null) {
        return const Err(MailboxNotFoundFailure());
      }
      final selected = await _connection.imap.selectMailbox(mailboxPath);
      if (selected is Err<MailboxState>) return Err(selected.failure);
      return action();
    }

    switch (op.type) {
      case PendingOpType.markSeen:
        return withMailbox(
          () => _connection.imap.storeFlags(
            uids: uids,
            flags: [r'\Seen'],
            add: true,
          ),
        );

      case PendingOpType.markUnseen:
        return withMailbox(
          () => _connection.imap.storeFlags(
            uids: uids,
            flags: [r'\Seen'],
            add: false,
          ),
        );

      case PendingOpType.flag:
        return withMailbox(
          () => _connection.imap.storeFlags(
            uids: uids,
            flags: [r'\Flagged'],
            add: true,
          ),
        );

      case PendingOpType.unflag:
        return withMailbox(
          () => _connection.imap.storeFlags(
            uids: uids,
            flags: [r'\Flagged'],
            add: false,
          ),
        );

      case PendingOpType.addKeyword:
      case PendingOpType.removeKeyword:
        final keyword = payload['keyword'] as String?;
        if (keyword == null) return okVoid;
        return withMailbox(
          () => _connection.imap.storeFlags(
            uids: uids,
            flags: [keyword],
            add: op.type == PendingOpType.addKeyword,
          ),
        );

      case PendingOpType.move:
        return withMailbox(() async {
          final targetPath = await _resolveTargetPath(accountId, payload);
          if (targetPath == null) return const Err(MailboxNotFoundFailure());
          return _connection.imap.moveMessages(
            uids: uids,
            targetPath: targetPath,
          );
        });

      case PendingOpType.deletePermanently:
        return withMailbox(() => _connection.imap.deletePermanently(uids));

      case PendingOpType.appendDraft:
        return _appendLocalMessage(accountId, payload);

      case PendingOpType.deleteDraft:
        return withMailbox(() => _connection.imap.deletePermanently(uids));

      case PendingOpType.send:
        return _sendQueued(accountId, payload);
    }
  }

  /// Hedef klasörü bulur; Arşiv yoksa oluşturur.
  Future<String?> _resolveTargetPath(
    int accountId,
    Map<String, dynamic> payload,
  ) async {
    final explicit = payload['targetPath'] as String?;
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final useIndex = payload['targetSpecialUse'] as int?;
    if (useIndex == null) return null;
    final use =
        SpecialUse.values[useIndex.clamp(0, SpecialUse.values.length - 1)];

    final existing = await _db.mailboxBySpecialUse(accountId, use);
    if (existing != null) return existing.path;

    // Arşiv klasörü yoksa oluşturulur — aksi hâlde arşivleme sessizce
    // başarısız olur ve kullanıcı iletisini kaybettiğini sanır.
    if (use != SpecialUse.archive) return null;

    final inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    final path = inbox == null ? 'Archive' : inbox.childPath('Archive');
    final created = await _connection.imap.createMailbox(path);
    if (created is Err<void>) return null;

    await _db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: path,
        name: 'Arşiv',
        specialUse: const Value(SpecialUse.archive),
        delimiter: Value(inbox?.delimiter ?? '.'),
        sortOrder: Value(FolderMapping.sortOrderFor(SpecialUse.archive)),
      ),
    );
    return path;
  }

  /// Yerel bir iletiyi sunucudaki bir klasöre yazar.
  ///
  /// Hem taslak kaydetmede hem de gönderim sonrası Gönderilenler'e yazma
  /// yeniden denemesinde kullanılır; hedef klasör yükte taşınır.
  Future<Result<void>> _appendLocalMessage(
    int accountId,
    Map<String, dynamic> payload,
  ) async {
    final messageId = payload['messageId'];
    if (messageId is! int) return okVoid;

    final row = await _db.messageById(messageId);
    if (row == null) return okVoid;

    final explicitPath = payload['targetPath'] as String?;
    final isSentCopy = payload['isSentCopy'] == true;
    final targetBox = await _db.mailboxBySpecialUse(
      accountId,
      isSentCopy ? SpecialUse.sent : SpecialUse.drafts,
    );
    final targetPath = explicitPath ?? targetBox?.path;
    if (targetPath == null) return okVoid;

    final outgoing = await _buildOutgoing(row, isDraft: !isSentCopy);
    if (outgoing is Err<OutgoingMessage>) return Err(outgoing.failure);

    final built = MimeBuilder.build((outgoing as Ok<OutgoingMessage>).value);
    if (built is Err<BuiltMessage>) return Err(built.failure);

    final appended = await _connection.imap.appendMessage(
      mimeSource: (built as Ok<BuiltMessage>).value.source,
      targetPath: targetPath,
      flags: isSentCopy ? [r'\Seen'] : [r'\Draft', r'\Seen'],
    );
    if (appended is Err<int?>) return Err(appended.failure);

    await _linkAppendedMessage(
      messageId: messageId,
      mailboxPath: targetPath,
      accountId: accountId,
      newUid: (appended as Ok<int?>).value,
    );
    return okVoid;
  }

  /// Sunucuya yazılan yerel kopyayı gerçek kayda bağlar.
  ///
  /// UID biliniyorsa yerel satır o UID'ye bağlanır — böylece bir sonraki
  /// eşitlemede kopya oluşmaz. UID bilinmiyorsa yerel satır silinir ve
  /// ileti eşitlemeyle sunucudan gelir; ikisi de kopya üretmez.
  Future<void> _linkAppendedMessage({
    required int messageId,
    required String mailboxPath,
    required int accountId,
    required int? newUid,
  }) async {
    final target = await _db.mailboxByPath(accountId, mailboxPath);
    if (target == null) return;

    if (newUid == null) {
      await _db.deleteMessages([messageId]);
      return;
    }

    final duplicate = await _db.messageByUid(target.id, newUid);
    if (duplicate != null && duplicate.id != messageId) {
      await _db.deleteMessages([messageId]);
      return;
    }

    await _db.updateMessage(
      messageId,
      MessagesCompanion(
        mailboxId: Value(target.id),
        uid: Value(newUid),
        isLocalOnly: const Value(false),
      ),
    );
  }

  /// Kuyruktaki iletiyi gönderir.
  ///
  /// SMTP gönderimi ile Gönderilenler'e `APPEND` AYRI iki adımdır. Tek işlem
  /// sayılsaydı APPEND hatasında gönderim tekrar denenir ve alıcı iletiyi
  /// iki kez alırdı.
  Future<Result<void>> _sendQueued(
    int accountId,
    Map<String, dynamic> payload,
  ) async {
    final messageId = payload['messageId'];
    if (messageId is! int) return okVoid;

    final row = await _db.messageById(messageId);
    if (row == null) return okVoid;
    if (row.outboxState == OutboxState.sent) return okVoid;

    final config = await _connection.smtpConfig(accountId);
    if (config == null) {
      return const Err(AuthFailure(detail: 'SMTP ayarı yok'));
    }

    await _db.updateMessage(
      messageId,
      const MessagesCompanion(outboxState: Value(OutboxState.sending)),
    );

    final outgoing = await _buildOutgoing(row, isDraft: false);
    if (outgoing is Err<OutgoingMessage>) {
      await _db.updateMessage(
        messageId,
        const MessagesCompanion(outboxState: Value(OutboxState.failed)),
      );
      return Err(outgoing.failure);
    }

    final sent = await _smtp.send(
      config: config,
      message: (outgoing as Ok<OutgoingMessage>).value,
    );
    if (sent is Err<SentMessage>) {
      await _db.updateMessage(
        messageId,
        const MessagesCompanion(outboxState: Value(OutboxState.queued)),
      );
      return Err(sent.failure);
    }

    // Gönderim başarılı — bu noktadan sonra ASLA tekrar gönderilmez.
    final sentMessage = (sent as Ok<SentMessage>).value;
    await _db.updateMessage(
      messageId,
      MessagesCompanion(
        outboxState: const Value(OutboxState.sent),
        outboxError: const Value(null),
        messageIdHeader: Value(sentMessage.messageId),
        dateUtc: Value(DateTime.now().toUtc()),
      ),
    );

    // Gönderilenler klasörüne yazma AYRI bir adımdır.
    await _appendToSent(accountId, messageId, sentMessage.mimeSource);
    return okVoid;
  }

  Future<void> _appendToSent(
    int accountId,
    int messageId,
    String mimeSource,
  ) async {
    final sentBox = await _db.mailboxBySpecialUse(accountId, SpecialUse.sent);
    if (sentBox == null) return;

    final appended = await _connection.imap.appendMessage(
      mimeSource: mimeSource,
      targetPath: sentBox.path,
      flags: [r'\Seen'],
    );

    if (appended is Err<int?>) {
      // Gönderim BAŞARILI olduğu için ileti kaybolmaz ve tekrar gönderilmez;
      // yalnızca Gönderilenler'e yazma işlemi kuyruğa alınıp tekrar denenir.
      await _db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.appendDraft,
          payloadJson: Value(
            jsonEncode({
              'messageId': messageId,
              'targetPath': sentBox.path,
              'isSentCopy': true,
            }),
          ),
          nextAttemptAt: Value(
            DateTime.now().toUtc().add(const Duration(minutes: 2)),
          ),
        ),
      );
      return;
    }

    await _linkAppendedMessage(
      messageId: messageId,
      mailboxPath: sentBox.path,
      accountId: accountId,
      newUid: (appended as Ok<int?>).value,
    );
  }

  Future<Result<OutgoingMessage>> _buildOutgoing(
    MessageRow row, {
    required bool isDraft,
  }) async {
    final account = await _db.accountById(row.accountId);
    if (account == null) {
      return const Err(UnknownFailure(detail: 'hesap yok'));
    }

    final body = await _db.bodyOf(row.id);
    final attachments = await _db.attachmentsOf(row.id);

    final to = EmailAddress.decodeList(row.toAddrJson);
    if (to.isEmpty && !isDraft) {
      return const Err(
        RecipientRejectedFailure(recipients: [], detail: 'alıcı yok'),
      );
    }

    return Ok(
      OutgoingMessage(
        from: EmailAddress(
          email: account.email,
          name: account.displayName.isEmpty ? null : account.displayName,
        ),
        to: to,
        cc: EmailAddress.decodeList(row.ccJson),
        bcc: EmailAddress.decodeList(row.bccJson),
        subject: row.subject,
        plainText: body?.plainText ?? '',
        html: body?.html,
        attachmentPaths: attachments
            .where((a) => a.isOutgoing && a.localPath != null)
            .map((a) => a.localPath!)
            .toList(),
        inReplyTo: row.inReplyTo,
        references: row.referencesRaw,
        messageId: row.messageIdHeader,
        isDraft: isDraft,
      ),
    );
  }

  // ------------------------------------------------------------- yardımcı

  /// İletileri klasörlerine göre gruplayıp tek komut hâlinde kuyruğa alır.
  Future<void> _enqueueByMailbox(
    List<MessageRow> rows,
    PendingOpType type, {
    Map<String, dynamic> extra = const {},
  }) async {
    final byMailbox = <int, List<MessageRow>>{};
    for (final row in rows) {
      if (row.uid == null) continue;
      byMailbox.putIfAbsent(row.mailboxId, () => []).add(row);
    }

    for (final entry in byMailbox.entries) {
      final mailbox = await _db.mailboxById(entry.key);
      if (mailbox == null) continue;
      await _db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: entry.value.first.accountId,
          type: type,
          payloadJson: Value(
            jsonEncode({
              'mailboxId': entry.key,
              'mailboxPath': mailbox.path,
              'uids': entry.value.map((r) => r.uid!).toList(),
              'messageIds': entry.value.map((r) => r.id).toList(),
              ...extra,
            }),
          ),
        ),
      );
    }
  }
}
