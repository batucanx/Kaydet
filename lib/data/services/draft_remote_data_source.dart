import 'dart:async';
import 'dart:typed_data';

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../repositories/mail_connection.dart';

/// IMAP sunucusu üzerindeki Taslaklar (Drafts) klasörü işlemlerinin uzak veri kaynağı sözleşmesi.
abstract interface class DraftRemoteDataSource {
  /// IMAP Drafts klasörüne MIME iletisini ekler (`APPEND`).
  ///
  /// Sunucu UIDPLUS destekliyorsa oluşturulan iletinin yeni UID'sini döner.
  Future<Result<int?>> appendDraft({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required String mimeSource,
  });

  /// IMAP Drafts klasöründeki eski taslak UID'lerini kalıcı olarak siler (`EXPUNGE`).
  Future<Result<void>> deleteDraftUids({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required List<int> uids,
  });

  /// IMAP sunucusundan taslak iletisinin gövdesini çeker.
  Future<Result<FetchedBody>> fetchDraftBody({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required int uid,
  });

  /// IMAP sunucusundan taslak iletisinin bir ek dosyasını çeker.
  Future<Result<Uint8List>> fetchDraftAttachment({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required int uid,
    required String partId,
  });
}

/// [MailConnection] ve [ImapService] üzerinden IMAP sunucusuyla konuşan veri kaynağı.
class ImapDraftRemoteDataSource implements DraftRemoteDataSource {
  const ImapDraftRemoteDataSource(this._connection);

  final MailConnection _connection;

  @override
  Future<Result<int?>> appendDraft({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required String mimeSource,
  }) {
    return _connection.exclusive<int?>(accountId, () async {
      return _connection.imap.appendMessage(
        mimeSource: mimeSource,
        targetPath: targetPath,
        encodedPath: encodedPath,
        flags: [r'\Draft', r'\Seen'],
      );
    });
  }

  @override
  Future<Result<void>> deleteDraftUids({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required List<int> uids,
  }) {
    if (uids.isEmpty) return Future.value(okVoid);
    return _connection.exclusive<void>(accountId, () async {
      final selected = await _connection.imap.selectMailbox(
        targetPath,
        encodedPath: encodedPath,
      );
      if (selected is Err<MailboxState>) return Err(selected.failure);
      return _connection.imap.deletePermanently(uids);
    });
  }

  @override
  Future<Result<FetchedBody>> fetchDraftBody({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required int uid,
  }) {
    return _connection.exclusive<FetchedBody>(accountId, () async {
      final selected = await _connection.imap.selectMailbox(
        targetPath,
        encodedPath: encodedPath,
      );
      if (selected is Err<MailboxState>) return Err(selected.failure);
      return _connection.imap.fetchBody(uid);
    });
  }

  @override
  Future<Result<Uint8List>> fetchDraftAttachment({
    required int accountId,
    required String targetPath,
    String? encodedPath,
    required int uid,
    required String partId,
  }) {
    return _connection.exclusive<Uint8List>(accountId, () async {
      final selected = await _connection.imap.selectMailbox(
        targetPath,
        encodedPath: encodedPath,
      );
      if (selected is Err<MailboxState>) return Err(selected.failure);
      return _connection.imap.fetchAttachment(uid, partId);
    });
  }
}
