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
import '../../domain/use_cases/label_keywords.dart';
import '../../domain/use_cases/text_extraction.dart';
import '../database/app_database.dart';
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
    this.onMessagesHandled,
  }) : _db = database,
       _connection = connection,
       _sync = syncEngine,
       _smtp = smtpService;

  final AppDatabase _db;
  final MailConnection _connection;
  final SyncEngine _sync;
  final SmtpService _smtp;

  /// İletiler bu cihazda "ele alındığında" (okundu işaretlendi, arşivlendi,
  /// silindi, taşındı) çağrılır — bildirimleri kaldırmak için. Repository
  /// bildirim eklentisini tanımaz; bağlantıyı çağıran kurar.
  final void Function(List<int> messageIds)? onMessagesHandled;

  AppDatabase get database => _db;
  SyncEngine get syncEngine => _sync;
  MailConnection get connection => _connection;

  /// En fazla deneme sayısı; sonrasında işlem kalıcı hata sayılır.
  static const int maxAttempts = 5;

  bool _processing = false;
  Future<void>? _activeRun;

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
  ///
  /// Yerel güncelleme ve kuyruğa ekleme tek transaction'dadır: aradaki
  /// kesintide (çökme) işlem kuyruğa hiç girmezse, bir sonraki senkronizasyon
  /// sunucudaki eski bayrağı yerelin üzerine yazıp kullanıcının eylemini
  /// sessizce geri alırdı.
  Future<void> setSeen(List<int> messageIds, bool seen) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    await _db.transaction(() async {
      await _db.updateMessages(
        messageIds,
        MessagesCompanion(isSeen: Value(seen)),
      );
      await _enqueueByMailbox(
        rows,
        seen ? PendingOpType.markSeen : PendingOpType.markUnseen,
      );
    });
    if (seen) onMessagesHandled?.call(messageIds);
    kickQueue(rows.first.accountId);
  }

  /// Sabitler / sabitlemeyi kaldırır (IMAP `\Flagged`).
  Future<void> setFlagged(List<int> messageIds, bool flagged) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;

    await _db.transaction(() async {
      await _db.updateMessages(
        messageIds,
        MessagesCompanion(isFlagged: Value(flagged)),
      );
      await _enqueueByMailbox(
        rows,
        flagged ? PendingOpType.flag : PendingOpType.unflag,
      );
    });
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
    if (rows.any((row) => row.accountId != accountId)) return;
    final targetBox = await _db.mailboxBySpecialUse(accountId, target);
    await _moveRowsToMailbox(rows, targetBox, fallbackTarget: target);
  }

  /// Moves mail to an exact folder identity, including user-created folders.
  Future<void> moveToFolder({
    required List<int> messageIds,
    required int targetMailboxId,
  }) async {
    if (messageIds.isEmpty) return;
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return;
    final accountId = rows.first.accountId;
    if (rows.any((row) => row.accountId != accountId)) return;
    final target = await _db.mailboxById(targetMailboxId);
    if (target == null || target.accountId != accountId) return;
    await _moveRowsToMailbox(rows, target);
  }

  Future<void> _moveRowsToMailbox(
    List<MessageRow> rows,
    MailboxRow? targetBox, {
    SpecialUse? fallbackTarget,
  }) async {
    if (rows.isEmpty) return;
    final accountId = rows.first.accountId;
    final actionableRows = rows
        .where((row) => row.mailboxId != targetBox?.id)
        .toList();
    if (actionableRows.isEmpty) return;

    // Yerel taslaklar sunucuya hiç gitmemiştir; doğrudan silinir.
    final localOnly = actionableRows
        .where((r) => r.isLocalOnly)
        .map((r) => r.id)
        .toList();
    if (localOnly.isNotEmpty) await _db.deleteMessages(localOnly);

    final remote = actionableRows
        .where((r) => !r.isLocalOnly && r.uid != null)
        .toList();
    if (remote.isEmpty) return;

    // Kuyruğa ekleme ve yerel silme tek transaction'da: aradaki kesintide
    // taşıma işlemi hiç kuyruğa girmeden mesaj yerelden kaybolmaz.
    await _db.transaction(() async {
      await _enqueueByMailbox(
        remote,
        PendingOpType.move,
        extra: {
          'targetPath': targetBox?.path,
          'targetSpecialUse':
              targetBox?.specialUse.index ?? fallbackTarget?.index,
        },
      );
      await _db.deleteMessages(remote.map((r) => r.id).toList());
    });
    onMessagesHandled?.call(remote.map((r) => r.id).toList());
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
    await _db.transaction(() async {
      if (remote.isNotEmpty) {
        await _enqueueByMailbox(remote, PendingOpType.deletePermanently);
      }
      await _db.deleteMessages(rows.map((r) => r.id).toList());
    });
    onMessagesHandled?.call(rows.map((r) => r.id).toList());
    kickQueue(rows.first.accountId);
  }

  Future<void> archive(List<int> messageIds) =>
      moveToMailbox(messageIds: messageIds, target: SpecialUse.archive);

  Future<void> markSpam(List<int> messageIds) =>
      moveToMailbox(messageIds: messageIds, target: SpecialUse.junk);

  /// Önbelleğe alınmış ileti gövdelerini temizler (Ayarlar > Önbelleği
  /// temizle). Zarf kaydı kalır; ileti tekrar açıldığında gövde yeniden
  /// indirilir.
  Future<int> pruneCachedBodies({Duration keep = const Duration(days: 30)}) =>
      _db.pruneOldBodies(keep: keep);

  /// Outlook tarzı yerel önbellek temizliği — klasörün `retentionLimit`ini
  /// (bkz. `RetentionPolicy`) aşan iletiler kademeli olarak küçültülür.
  /// Sabitlenmiş/taslak/gönderilmeyi bekleyen iletiler `trimCandidateIds`
  /// sayesinde HİÇBİR ZAMAN aday olmaz. Her senkron sonunda fırsatçı olarak
  /// (bkz. `SyncController`) ve periyodik arka plan görevinde (bkz.
  /// `background_sync.dart`) çağrılır — "uygulama kapanınca" gibi güvenilir
  /// olmayan bir tetikleyiciye dayanmaz.
  ///
  /// Bir klasörde limit hiç aşılmamışsa (çoğu kullanıcı için çoğu zaman
  /// böyledir) her iki sorgu da boş döner — dosya silme/DB yazma hiç
  /// çalışmaz, maliyet indeksli bir SELECT'ten ibaret kalır.
  Future<void> trimMailbox(int mailboxId) async {
    final mailbox = await _db.mailboxById(mailboxId);
    if (mailbox == null) return;
    final limit = mailbox.retentionLimit;

    // Kademe 1 (limitin hemen üzeri): sadece cihaza inmiş ekler silinir,
    // mesaj + metin gövdesi kalır.
    final strippable = await _db.trimCandidateIds(mailboxId, keepNewest: limit);
    if (strippable.isNotEmpty) {
      final localAttachments = await _db.attachmentsForMessages(strippable);
      final clearedIds = <int>[];
      for (final attachment in localAttachments) {
        final path = attachment.localPath;
        if (path == null) continue;
        try {
          await File(path).delete();
        } on FileSystemException {
          // Dosya zaten yoksa/erişilemezse DB kaydı yine de temizlenir —
          // asıl amaç disk alanıydı, dosya zaten kaybolmuşsa iş bitmiştir.
        }
        clearedIds.add(attachment.id);
      }
      await _db.clearAttachmentPaths(clearedIds);
    }

    // Kademe 2 (limitin çok ötesi): tam satır silme — mesaj + gövde + ek +
    // FTS girdisi (bkz. `AppDatabase.deleteMessages`). Gerekirse kullanıcı
    // "daha fazla göster" ile sunucudan yeniden çekebilir.
    final deletable = await _db.trimCandidateIds(
      mailboxId,
      keepNewest: limit * RetentionPolicy.deleteBeyondFactor,
    );
    if (deletable.isNotEmpty) {
      await _db.deleteMessages(deletable);
      // Silinen eski iletiler sunucuda durur; "daha fazla göster" onlara
      // yeniden ulaşabilsin.
      await _db.updateMailboxSync(mailboxId, hasMoreOnServer: true);
    }
  }

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

    final account = await _db.accountById(rows.first.accountId);
    // Sunucu özel anahtar kelime desteklemiyorsa etiket yalnızca yereldir.
    final shouldEnqueue = account?.supportsKeywords == true;

    await _db.transaction(() async {
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

      if (shouldEnqueue) {
        await _enqueueByMailbox(
          rows.where((r) => r.uid != null).toList(),
          add ? PendingOpType.addKeyword : PendingOpType.removeKeyword,
          extra: {'keyword': labelImapKeyword(labelName)},
        );
      }
    });

    if (shouldEnqueue) kickQueue(rows.first.accountId);
  }

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
    bool markSourceAnswered = false,
    bool markSourceForwarded = false,
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
    //
    // Durum güncellemesi ve kuyruğa ekleme tek transaction'dadır: aradaki
    // kesintide ileti "queued" görünüp hiçbir PendingOperation oluşmazsa,
    // kullanıcıya sonsuza dek "gönderiliyor" gösterilen ama asla
    // gönderilmeyen bir ileti kalırdı.
    final sentBox = await _db.mailboxBySpecialUse(accountId, SpecialUse.sent);
    await _db.transaction(() async {
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

      if (replyToMessageId != null &&
          (markSourceAnswered || markSourceForwarded)) {
        await _markSourceMessage(
          replyToMessageId,
          answered: markSourceAnswered,
          forwarded: markSourceForwarded,
        );
      }
    });

    // Kişi öğrenme kritik yola dahil değil: gönderim zaten kuyruğa girdi,
    // burada bir aksaklık en kötü ihtimalle bir sonraki yazmada otomatik
    // tamamlamada bu adresin eksik kalması demektir — gönderimi etkilemez.
    try {
      await _captureContacts(accountId, [to, cc, bcc]);
    } on Object catch (_) {
      // Gönderim zaten kuyrukta; kişi kaydı başarısız olursa istisna
      // yukarı taşınıp kullanıcıya "gönderilemedi" gösterilmemeli (yeniden
      // gönderim ileti çiftlenmesine yol açardı).
    }
    return id;
  }

  /// Bir iletinin gönderim durumunu izler; ileti silinirse `null` yayınlar.
  ///
  /// Yazma ekranı kapandıktan sonra gönderimin sonucunu kullanıcıya bildirmek
  /// için kullanılır (bkz. `SendFeedback`): gönderim arka planda ve bazen
  /// dakikalar sonra tamamlanır.
  Stream<OutboxState?> watchOutboxState(int messageId) => _db
      .watchMessageById(messageId)
      .map((message) => message?.outboxState)
      .distinct();

  /// Alıcıları yerel kişi defterine ekler/günceller (bkz.
  /// `AppDatabase.upsertContact`) — yazma ekranındaki otomatik tamamlama ve
  /// Kişiler sekmesi bu şekilde beslenir. Sunucudan gelen iletilerin
  /// göndericisi ise `SyncEngine` tarafından ayrıca yakalanır.
  Future<void> _captureContacts(
    int accountId,
    List<String> rawAddressLists,
  ) async {
    final byEmail = <String, EmailAddress>{};
    for (final raw in rawAddressLists) {
      for (final address in EmailAddress.parseInput(raw)) {
        if (!address.isValid) continue;
        byEmail[address.email.toLowerCase()] = address;
      }
    }
    for (final address in byEmail.values) {
      await _db.upsertContact(
        accountId: accountId,
        email: address.email,
        name: address.name,
      );
    }
  }

  /// Yanıtlanan/iletilen kaynak iletiyi işaretler.
  ///
  /// Gmail/Outlook'taki gibi yanıt/iletme oku "Gönder"e basılır basılmaz
  /// görünür; diğer bayraklarla aynı iyimser desen (bkz. [setFlagged]) —
  /// gerçek teslimatı beklemez, kalıcı gönderim hatasında bile işaret kalır.
  /// `\Answered` standart bir IMAP bayrağıdır ve her sunucuda desteklenir;
  /// `$Forwarded` yaygın ama standart dışı bir anahtar kelimedir, bu yüzden
  /// [setLabel]'daki gibi yalnızca sunucu özel anahtar kelime destekliyorsa
  /// sunucuya gönderilir — desteklenmese de yerel işaret her zaman kalır.
  Future<void> _markSourceMessage(
    int sourceId, {
    required bool answered,
    required bool forwarded,
  }) async {
    final row = await _db.messageById(sourceId);
    if (row == null) return;

    await _db.updateMessage(
      sourceId,
      MessagesCompanion(
        isAnswered: answered ? const Value(true) : const Value.absent(),
        isForwarded: forwarded ? const Value(true) : const Value.absent(),
      ),
    );

    if (row.uid == null) return; // yerel taslak, sunucuda karşılığı yok

    if (answered) {
      await _enqueueByMailbox(
        [row],
        PendingOpType.addKeyword,
        extra: {'keyword': r'\Answered'},
      );
    }
    if (forwarded) {
      final account = await _db.accountById(row.accountId);
      if (account?.supportsKeywords == true) {
        await _enqueueByMailbox(
          [row],
          PendingOpType.addKeyword,
          extra: {'keyword': r'$Forwarded'},
        );
      }
    }
  }

  // ------------------------------------------------------------ kuyruk

  /// Bekleyen işlemleri sunucuya uygular.
  ///
  /// `_processing` bayrağı yalnızca AYNI isolate içindeki tekrarlı çağrıları
  /// engeller — arka plan senkronizasyonu (WorkManager) ayrı bir isolate'ta
  /// kendi `MailRepository` örneğini kurduğundan bu bayrağı paylaşmaz. Gerçek
  /// çift-işlem koruması `claimDueOperations`'ın veritabanı seviyesindeki
  /// atomik `pending → running` geçişidir; bu, isolate/süreç sınırlarını
  /// aşan tek güvenilir kilit noktasıdır (bkz. `app_database.dart`).
  Future<void> processQueue(int accountId) async {
    if (_processing) return;
    _processing = true;
    final finished = Completer<void>();
    _activeRun = finished.future;
    try {
      final operations = await _db.claimDueOperations(accountId);
      if (operations.isEmpty) return;

      final connected = await _connection.ensureConnected(accountId);
      if (connected is Err<void>) {
        // Hiçbir işlem gerçekten denenmedi — sahiplenmeyi hemen bırak, aksi
        // hâlde ağ geri geldiğinde kira süresi dolana kadar gereksiz gecikir.
        await _db.releaseOperations(operations.map((op) => op.id).toList());
        return;
      }

      for (final op in operations) {
        // Bu işlemi yürütmeye başlamadan hemen önce kirasını tazele: parti
        // içindeki önceki işlemler zaman aldıysa (ör. yavaş bir gönderim),
        // bu işlem kalan değil TAZE bir kira süresiyle başlar.
        await _db.renewLease(op.id);
        // `op.status`, `claimDueOperations`'ın DÖNDÜĞÜ (sahiplenmeden ÖNCEKİ)
        // anlık görüntüdür: `running` ise bu, süresi dolmuş bir kiradan
        // yeniden sahiplenildiği (önceki işlemcinin muhtemelen çöktüğü)
        // anlamına gelir — bkz. `_sendQueued`'daki `claimOutboxSend` çağrısı.
        final wasReclaimed = op.status == PendingOpStatus.running;
        final result = await _execute(accountId, op, wasReclaimed);
        await result.fold(
          (_) => _db.completeOperation(op.id),
          (failure) => _handleFailure(op, failure),
        );
      }
    } finally {
      _processing = false;
      _activeRun = null;
      finished.complete();
    }
  }

  /// [kickQueue]'nun başlattığı tur bitene kadar bekler.
  ///
  /// Arka plan isolate'leri (bildirim eylemleri, periyodik görev) işlem
  /// kuyruğa alındıktan hemen sonra veritabanını ve bağlantıyı kapatır;
  /// bekletilmeyen bir tur yarıda kesilir ve işlem bir sonraki eşitlemeye
  /// kalır. `_processing` bayrağı olduğu için ikinci bir `processQueue`
  /// çağrısı çalışan turu beklemez, hemen döner — bu yüzden ayrı bir bekleme
  /// noktası gerekir.
  Future<void> waitForQueue() async {
    final run = _activeRun;
    if (run != null) await run;
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

  Future<Result<void>> _execute(
    int accountId,
    PendingOperationRow op,
    bool wasReclaimed,
  ) async {
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
        return _sendQueued(accountId, payload, wasReclaimed: wasReclaimed);
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
    Map<String, dynamic> payload, {
    required bool wasReclaimed,
  }) async {
    final messageId = payload['messageId'];
    if (messageId is! int) return okVoid;

    final row = await _db.messageById(messageId);
    if (row == null) return okVoid;
    if (row.outboxState == OutboxState.sent) return okVoid;

    final config = await _connection.smtpConfig(accountId);
    if (config == null) {
      return const Err(AuthFailure(detail: 'SMTP ayarı yok'));
    }

    // Yukarıdaki `outboxState == sent` kontrolü ile buradaki geçiş arasında
    // başka bir işlemci (örn. arka plan isolate'ı) aynı `send` işlemini
    // eşzamanlı sahiplenip göndermiş/göndermekte olabilir. `claimOutboxSend`
    // bunu tek atomik bir `UPDATE` ile kapatır: 0 dönerse ileti başka bir
    // işlemcinin elindedir (az önce gönderilmiş VEYA hâlâ gönderiliyor),
    // burada İKİNCİ KEZ göndermek yerine sessizce çıkılır.
    //
    // `wasReclaimed` yalnızca bu işlemi `processQueue`'nun süresi dolmuş
    // (dolayısıyla önceki sahibi muhtemelen çökmüş — bkz. `renewLease`)
    // bir kiradan yeniden sahiplendiği durumda `true`dur; bu durumda
    // `sending`'de takılı kalmış bir ileti de kurtarma için sahiplenilebilir
    // sayılır. Taze bir sahiplenmede `sending` ASLA kurtarılabilir sayılmaz
    // — aksi hâlde bu kontrol hiçbir şeyi engellemeyen bir "her zaman evet"
    // kilidine döner ve alıcı aynı e-postayı iki kez alabilir.
    final claimed = await _db.claimOutboxSend(
      messageId,
      allowReclaim: wasReclaimed,
    );
    if (claimed == 0) return okVoid;

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
