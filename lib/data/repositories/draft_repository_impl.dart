import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../../core/avatar.dart' show domainOf;
import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/repositories/draft_repository.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../../domain/use_cases/text_extraction.dart';
import '../database/app_database.dart';
import '../services/attachment_files.dart';
import '../services/draft_remote_data_source.dart';
import '../services/smtp_service.dart';
import 'mail_connection.dart';
import 'sync_engine.dart';

/// Eşitleme tanılaması yalnızca debug derlemede yazılır; release logcat'ine
/// taslak/hesap kimlikleri ve konu sızmasın.
void _log(String message) {
  // ignore: avoid_print
  if (kDebugMode) print(message);
}

class DraftRepositoryImpl implements DraftRepository {
  DraftRepositoryImpl({
    required AppDatabase database,
    required DraftRemoteDataSource remoteDataSource,
    required MailConnection connection,
    required SyncEngine syncEngine,
  })  : _db = database,
        _remoteDataSource = remoteDataSource,
        _connection = connection,
        _syncEngine = syncEngine;

  final AppDatabase _db;
  final DraftRemoteDataSource _remoteDataSource;
  final MailConnection _connection;
  final SyncEngine _syncEngine;

  /// Aynı taslak üzerinde eşzamanlı remote senkronizasyonların yarışmasını önlemek için kilitler.
  final Map<int, Lock> _draftLocks = {};

  Lock _lockFor(int draftId) => _draftLocks.putIfAbsent(draftId, () => Lock());

  static final Random _rng = Random();

  static String _randomToken() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _guessMimeType(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
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

  /// Hesaba ait Taslaklar (Drafts) klasörünü güvenilir biçimde bulur.
  Future<MailboxRow?> _resolveDraftsMailbox(int accountId) async {
    final box = await _db.mailboxBySpecialUse(accountId, SpecialUse.drafts);
    if (box != null) return box;

    final all = await _db.mailboxesOf(accountId);
    for (final m in all) {
      final use = FolderMapping.resolve(
        path: m.path,
        delimiter: m.delimiter,
        serverFlagUse: m.specialUse,
      );
      if (use == SpecialUse.drafts) {
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(m.id))).write(
          const MailboxesCompanion(specialUse: Value(SpecialUse.drafts)),
        );
        return m;
      }
    }

    for (final m in all) {
      final lower = m.path.toLowerCase();
      if (lower.contains('draft') || lower.contains('taslak')) {
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(m.id))).write(
          const MailboxesCompanion(specialUse: Value(SpecialUse.drafts)),
        );
        return m;
      }
    }
    return null;
  }

  @override
  Future<int> saveDraftLocal({
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
    final drafts = await _resolveDraftsMailbox(accountId);
    final account = await _db.accountById(accountId);
    final mailboxId = drafts?.id ??
        (await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox))?.id;
    if (mailboxId == null) return -1;

    // Kararlı Message-ID başlığı: taslağın yaşam döngüsü boyunca korunur.
    String messageIdHeader;
    if (draftId != null && draftId > 0) {
      final existing = await _db.messageById(draftId);
      if (existing?.messageIdHeader != null &&
          existing!.messageIdHeader!.isNotEmpty) {
        messageIdHeader = existing.messageIdHeader!;
      } else {
        final domain = domainOf(account?.email ?? 'kaydet.local');
        messageIdHeader =
            '<kaydet-draft-${DateTime.now().millisecondsSinceEpoch}-${_randomToken()}@$domain>';
      }
    } else {
      final domain = domainOf(account?.email ?? 'kaydet.local');
      messageIdHeader =
          '<kaydet-draft-${DateTime.now().millisecondsSinceEpoch}-${_randomToken()}@$domain>';
    }

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
      messageIdHeader: Value(messageIdHeader),
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

  @override
  Future<Result<void>> syncDraftRemote(int draftId) =>
      _lockFor(draftId).synchronized(() async {
        _log('[DRAFT_SYNC] syncDraftRemote başladı. draftId: $draftId');
        final row = await _db.messageById(draftId);
        if (row == null || row.isDeleted || row.outboxState == OutboxState.sent) {
          _log('[DRAFT_SYNC] Taslak bulunamadı veya silinmiş/gönderilmiş (draftId: $draftId)');
          return okVoid;
        }

        final accountId = row.accountId;
        final draftsBox = await _resolveDraftsMailbox(accountId);
        if (draftsBox == null) {
          _log('[DRAFT_SYNC] HATA: Taslaklar klasörü bulunamadı (accountId: $accountId)');
          return const Err(MailboxNotFoundFailure());
        }

        final account = await _db.accountById(accountId);
        if (account == null) {
          _log('[DRAFT_SYNC] HATA: Hesap bulunamadı (accountId: $accountId)');
          return const Err(UnknownFailure(detail: 'hesap yok'));
        }

        final oldUid = row.uid;
        final body = await _db.bodyOf(draftId);
        final attachments = await _db.attachmentsOf(draftId);

        // Ek dosyaları kontrol et (mevcut yerel dosyalar)
        final effectivePaths = <String>[];
        for (final a in attachments) {
          if (a.localPath != null && File(a.localPath!).existsSync()) {
            effectivePaths.add(a.localPath!);
          }
        }

        final outgoing = OutgoingMessage(
          from: EmailAddress(
            email: account.email,
            name: account.displayName.isEmpty ? null : account.displayName,
          ),
          to: EmailAddress.decodeList(row.toAddrJson),
          cc: EmailAddress.decodeList(row.ccJson),
          bcc: EmailAddress.decodeList(row.bccJson),
          subject: row.subject,
          plainText: body?.plainText ?? '',
          html: body?.html,
          attachmentPaths: effectivePaths,
          inReplyTo: row.inReplyTo,
          references: row.referencesRaw,
          messageId: row.messageIdHeader,
          isDraft: true,
        );

        final built = await MimeBuilder.buildSourceInIsolate(
          outgoing,
          skipMissingAttachments: true,
        );
        if (built is Err<WireMessage>) {
          _log('[DRAFT_SYNC] MIME oluşturma hatası: ${built.failure}');
          return Err(built.failure);
        }

        final source = (built as Ok<WireMessage>).value.source;

        _log(
          '[DRAFT_SYNC] IMAP APPEND gönderiliyor... '
          'path: "${draftsBox.path}", encoded: "${draftsBox.encodedPath}", '
          'subject: "${row.subject}", messageId: "${row.messageIdHeader}"',
        );

        final appendResult = await _remoteDataSource.appendDraft(
          accountId: accountId,
          targetPath: draftsBox.path,
          encodedPath: draftsBox.encodedPath,
          mimeSource: source,
        );

        if (appendResult is Err<int?>) {
          _log(
            '[DRAFT_SYNC] IMAP APPEND başarısız: ${appendResult.failure}. '
            'Çevrimdışı kuyruğuna (PendingOperations) alınıyor...',
          );
          await _enqueueOrUpdatePendingDraft(
            accountId: accountId,
            draftId: draftId,
            replaceUid: oldUid,
          );
          return Err(appendResult.failure);
        }

        var newUid = (appendResult as Ok<int?>).value;
        _log('[DRAFT_SYNC] IMAP APPEND BAŞARILI! Dönen UID: $newUid, Eski UID: $oldUid');

        // Sunucu UIDPLUS desteklemediği için APPENDUID dönmediyse UID'yi bulmayı dene
        if (newUid == null &&
            row.messageIdHeader != null &&
            row.messageIdHeader!.isNotEmpty) {
          final searchRes = await _connection.imap.searchUids(
            'HEADER Message-ID "${row.messageIdHeader}"',
          );
          if (searchRes is Ok<List<int>> && searchRes.value.isNotEmpty) {
            newUid = searchRes.value.last;
            _log('[DRAFT_SYNC] Message-ID ile bulunan UID: $newUid');
          }
        }

        if (newUid == null) {
          final selectRes = await _connection.imap.selectMailbox(
            draftsBox.path,
            encodedPath: draftsBox.encodedPath,
          );
          if (selectRes is Ok<MailboxState>) {
            final state = selectRes.value;
            if (state.uidNext > 1) {
              newUid = state.uidNext - 1;
              _log('[DRAFT_SYNC] UIDPLUS yok, tahmin edilen UID: $newUid');
            }
          }
        }

        // Eski taslak varsa sunucudan kaldır (mükerrerliği önleme)
        if (oldUid != null && newUid != null && oldUid != newUid) {
          _log('[DRAFT_SYNC] Eski taslak UID ($oldUid) IMAP sunucusundan siliniyor...');
          await _remoteDataSource.deleteDraftUids(
            accountId: accountId,
            targetPath: draftsBox.path,
            encodedPath: draftsBox.encodedPath,
            uids: [oldUid],
          );
        }

        // Yerel kaydı sunucu kimliğiyle güncelle
        await _db.updateMessage(
          draftId,
          MessagesCompanion(
            uid: newUid == null ? const Value.absent() : Value(newUid),
            mailboxId: Value(draftsBox.id),
            isLocalOnly: Value(newUid == null),
            dateUtc: Value(DateTime.now().toUtc()),
          ),
        );

        if (newUid != null) {
          final currentDraftsBox = await _db.mailboxById(draftsBox.id);
          if (currentDraftsBox != null) {
            final newTotal =
                currentDraftsBox.totalCount + (oldUid == null ? 1 : 0);
            final nextUid = (currentDraftsBox.uidNext != null &&
                    currentDraftsBox.uidNext! > newUid)
                ? currentDraftsBox.uidNext!
                : newUid + 1;
            await _db.updateMailboxSync(
              draftsBox.id,
              uidNext: nextUid,
              totalCount: newTotal,
            );
          }
        }

        // Başarılı senkronizasyon sonrası kuyruğu temizle
        await _db.cancelPendingDraftOperations(draftId);
        _log('[DRAFT_SYNC] Taslak ($draftId) sunucu ile başarıyla eşitlendi (UID: $newUid).');

        return okVoid;
      });

  @override
  Future<void> discardDraft(int draftId) async {
    await _db.cancelPendingDraftOperations(draftId);
    final row = await _db.messageById(draftId);
    if (row != null && row.uid != null) {
      final draftsBox = await _resolveDraftsMailbox(row.accountId);
      if (draftsBox != null) {
        await _remoteDataSource.deleteDraftUids(
          accountId: row.accountId,
          targetPath: draftsBox.path,
          encodedPath: draftsBox.encodedPath,
          uids: [row.uid!],
        );
      }
    }
    await _db.deleteMessages([draftId]);
  }

  @override
  Future<void> cleanupSentDraft({
    required int accountId,
    required int draftId,
    int? serverUid,
  }) async {
    await _db.cancelPendingDraftOperations(draftId);
    if (serverUid != null) {
      final draftsBox = await _resolveDraftsMailbox(accountId);
      if (draftsBox != null) {
        await _remoteDataSource.deleteDraftUids(
          accountId: accountId,
          targetPath: draftsBox.path,
          encodedPath: draftsBox.encodedPath,
          uids: [serverUid],
        );
      }
    }
  }

  @override
  Future<Result<void>> ensureDraftBodyLoaded(int draftId) async {
    final row = await _db.messageById(draftId);
    if (row == null || row.uid == null) return okVoid;

    // Gövde zaten çekilmişse tekrar çekmeye gerek yok
    if (row.bodyFetchedAt != null && await _db.bodyOf(draftId) != null) {
      return okVoid;
    }

    final mailbox = await _db.mailboxById(row.mailboxId);
    if (mailbox == null) return const Err(MailboxNotFoundFailure());

    final fetched = await _remoteDataSource.fetchDraftBody(
      accountId: row.accountId,
      targetPath: mailbox.path,
      encodedPath: mailbox.encodedPath,
      uid: row.uid!,
    );
    if (fetched is Err<FetchedBody>) return Err(fetched.failure);

    final body = (fetched as Ok<FetchedBody>).value;
    await _syncEngine.storeBody(row, body);

    // Varsa ek dosyaları cihazda hazır et (yerel dosya olarak indir)
    final attachments = await _db.attachmentsOf(draftId);
    for (final attachment in attachments) {
      if (attachment.isInline) continue;
      if (attachment.localPath != null &&
          File(attachment.localPath!).existsSync()) {
        continue;
      }
      if (attachment.partId.isNotEmpty) {
        final dataResult = await _remoteDataSource.fetchDraftAttachment(
          accountId: row.accountId,
          targetPath: mailbox.path,
          encodedPath: mailbox.encodedPath,
          uid: row.uid!,
          partId: attachment.partId,
        );
        if (dataResult is Ok<Uint8List>) {
          final dir = await getApplicationSupportDirectory();
          final folder = Directory(
            p.join(
              dir.path,
              AttachmentFiles.directoryName,
              '${row.id}',
              '${attachment.id}',
            ),
          );
          if (!folder.existsSync()) folder.createSync(recursive: true);
          final file = File(
            p.join(
              folder.path,
              AttachmentFiles.safeFileName(attachment.fileName),
            ),
          );
          await file.writeAsBytes(dataResult.value);
          await (_db.update(_db.attachments)
                ..where((a) => a.id.equals(attachment.id)))
              .write(
            AttachmentsCompanion(
              localPath: Value(file.path),
              isOutgoing: const Value(true),
            ),
          );
        }
      }
    }

    return okVoid;
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
      final rawName = p.basename(path);
      final cleanName = AttachmentFiles.cleanPickedName(
        rawName,
        sourcePath: path,
      );
      final size = file.existsSync() ? file.lengthSync() : 0;
      await _db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: messageId,
          partId: const Value(''),
          fileName: Value(cleanName),
          mimeType: Value(_guessMimeType(cleanName)),
          sizeBytes: Value(size),
          localPath: Value(path),
          isOutgoing: const Value(true),
        ),
      );
    }
  }

  Future<void> _enqueueOrUpdatePendingDraft({
    required int accountId,
    required int draftId,
    int? replaceUid,
  }) async {
    final existing = await _db.pendingDraftOperationsFor(draftId);
    final payload = jsonEncode({
      'messageId': draftId,
      'replaceUid': replaceUid,
      'accountId': accountId,
    });
    if (existing.isNotEmpty) {
      for (final op in existing) {
        await (_db.update(_db.pendingOperations)
              ..where((p) => p.id.equals(op.id)))
            .write(
          PendingOperationsCompanion(
            payloadJson: Value(payload),
            nextAttemptAt: const Value(null),
            attemptCount: const Value(0),
          ),
        );
      }
    } else {
      await _db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.appendDraft,
          payloadJson: Value(payload),
        ),
      );
    }
  }
}
