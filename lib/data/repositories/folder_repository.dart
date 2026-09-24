import 'package:drift/drift.dart';

import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../data/database/app_database.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/folder_mapping.dart';
import 'mail_connection.dart';

/// IMAP folder mutations and their local Drift reconciliation.
///
/// Remote mutations are server-first. A local mailbox is committed only after
/// IMAP confirms the operation; local-only preferences remain in Drift.
class FolderRepository {
  FolderRepository({
    required AppDatabase database,
    required MailConnection connection,
  }) : _db = database,
       _connection = connection;

  final AppDatabase _db;
  final MailConnection _connection;

  Future<Result<MailboxRow>> createFolder({
    required int accountId,
    required String name,
    int? parentMailboxId,
    bool atRoot = false,
  }) async {
    try {
      final trimmed = name.trim();
      final mailboxes = await _db.mailboxesOf(accountId);
      final inbox = mailboxes
          .where((m) => m.specialUse == SpecialUse.inbox)
          .firstOrNull;
      MailboxRow? parent;
      if (parentMailboxId != null) {
        parent = mailboxes.where((m) => m.id == parentMailboxId).firstOrNull;
        if (parent == null) return const Err(MailboxNotFoundFailure());
      } else if (!atRoot) {
        parent = inbox;
      }

      final delimiter = (parent ?? inbox)?.delimiter ?? '.';
      if (parent != null && delimiter.isEmpty) {
        return const Err(InvalidFolderMoveFailure());
      }
      if (trimmed.isEmpty ||
          (delimiter.isNotEmpty && trimmed.contains(delimiter))) {
        return const Err(InvalidFolderNameFailure());
      }
      final path = parent == null ? trimmed : parent.childPath(trimmed);
      if (mailboxes.any((m) => trLower(m.path) == trLower(path))) {
        return const Err(DuplicateFolderFailure());
      }

      final connected = await _connection.ensureConnected(accountId);
      if (connected is Err<void>) return Err(connected.failure);
      final created = await _connection.imap.createMailbox(path);
      if (created is Err<void>) return Err(created.failure);

      final nextOrder = mailboxes.isEmpty
          ? 0
          : mailboxes.map((m) => m.sortOrder).reduce((a, b) => a > b ? a : b) +
                1;
      final id = await _db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: path,
          name: trimmed,
          delimiter: Value(delimiter.isEmpty ? '.' : delimiter),
          sortOrder: Value(nextOrder),
        ),
      );
      final row = await _db.mailboxById(id);
      return row == null ? const Err(StorageFailure()) : Ok(row);
    } on Object catch (error) {
      return Err(StorageFailure(detail: error.toString()));
    }
  }

  Future<void> setFavorite(int mailboxId, bool value) =>
      _db.setMailboxFavorite(mailboxId, value);

  /// Reorder one sibling group. Parent/other account rows are never touched.
  Future<void> reorderSiblings({
    required int accountId,
    required int? parentMailboxId,
    required List<int> orderedIds,
  }) async {
    final all = await _db.mailboxesOf(accountId);
    final parent = parentMailboxId == null
        ? null
        : all.where((m) => m.id == parentMailboxId).firstOrNull;
    if (parentMailboxId != null && parent == null) {
      throw const MailboxNotFoundFailure();
    }
    final parentPath = parent?.path;
    final selected = orderedIds
        .map((id) => all.where((mailbox) => mailbox.id == id).firstOrNull)
        .toList();
    if (orderedIds.isEmpty ||
        orderedIds.toSet().length != orderedIds.length ||
        selected.any(
          (mailbox) => mailbox == null || _parentPath(mailbox) != parentPath,
        )) {
      throw const InvalidFolderMoveFailure();
    }
    await _db.reorderMailboxes(orderedIds);
  }

  Future<void> reorderFolders(List<int> orderedIds) =>
      _db.reorderMailboxes(orderedIds);

  Future<Result<void>> renameFolder({
    required int accountId,
    required int mailboxId,
    required String newName,
  }) async {
    try {
      final trimmed = newName.trim();
      if (trimmed.isEmpty) return const Err(InvalidFolderNameFailure());
      final mailboxes = await _db.mailboxesOf(accountId);
      final mailbox = mailboxes.where((m) => m.id == mailboxId).firstOrNull;
      if (mailbox == null) return const Err(MailboxNotFoundFailure());
      if (mailbox.specialUse != SpecialUse.custom) {
        return const Err(SystemFolderProtectedFailure());
      }
      if (mailbox.delimiter.isNotEmpty && trimmed.contains(mailbox.delimiter)) {
        return const Err(InvalidFolderNameFailure());
      }
      if (trimmed == mailbox.name) return okVoid;
      final parentPath = _parentPath(mailbox);
      final newPath = parentPath == null
          ? trimmed
          : '$parentPath${mailbox.delimiter}$trimmed';
      if (mailboxes.any(
        (m) => m.id != mailboxId && trLower(m.path) == trLower(newPath),
      )) {
        return const Err(DuplicateFolderFailure());
      }

      final connected = await _connection.ensureConnected(accountId);
      if (connected is Err<void>) return Err(connected.failure);
      final renamed = await _connection.imap.renameMailbox(
        path: mailbox.path,
        encodedPath: mailbox.encodedPath,
        delimiter: mailbox.delimiter,
        newPath: newPath,
      );
      if (renamed is Err<void>) return Err(renamed.failure);
      await _db.renameMailboxTree(
        mailboxId: mailboxId,
        oldPath: mailbox.path,
        newPath: newPath,
        newName: trimmed,
        delimiter: mailbox.delimiter,
      );
      return okVoid;
    } on Object catch (error) {
      return Err(StorageFailure(detail: error.toString()));
    }
  }

  Future<Result<void>> moveFolder({
    required int accountId,
    required int mailboxId,
    required int? newParentId,
  }) async {
    try {
      final all = await _db.mailboxesOf(accountId);
      final mailbox = all.where((m) => m.id == mailboxId).firstOrNull;
      if (mailbox == null) return const Err(MailboxNotFoundFailure());
      if (mailbox.specialUse != SpecialUse.custom) {
        return const Err(SystemFolderProtectedFailure());
      }
      final parent = newParentId == null
          ? null
          : all.where((m) => m.id == newParentId).firstOrNull;
      if (newParentId != null && parent == null) {
        return const Err(MailboxNotFoundFailure());
      }
      if (parent?.id == mailboxId) return const Err(InvalidFolderMoveFailure());
      if (parent != null && parent.delimiter != mailbox.delimiter) {
        return const Err(InvalidFolderMoveFailure());
      }
      final subtreePrefix = '${mailbox.path}${mailbox.delimiter}';
      if (parent != null && parent.path.startsWith(subtreePrefix)) {
        return const Err(InvalidFolderMoveFailure());
      }
      final leaf = FolderMapping.leafName(mailbox.path, mailbox.delimiter);
      final newPath = parent == null ? leaf : parent.childPath(leaf);
      if (newPath == mailbox.path) return okVoid;
      if (all.any(
        (m) => m.id != mailboxId && trLower(m.path) == trLower(newPath),
      )) {
        return const Err(DuplicateFolderFailure());
      }

      final connected = await _connection.ensureConnected(accountId);
      if (connected is Err<void>) return Err(connected.failure);
      final renamed = await _connection.imap.renameMailbox(
        path: mailbox.path,
        encodedPath: mailbox.encodedPath,
        delimiter: mailbox.delimiter,
        newPath: newPath,
      );
      if (renamed is Err<void>) return Err(renamed.failure);
      await _db.renameMailboxTree(
        mailboxId: mailboxId,
        oldPath: mailbox.path,
        newPath: newPath,
        newName: mailbox.name,
        delimiter: mailbox.delimiter,
      );
      return okVoid;
    } on Object catch (error) {
      return Err(StorageFailure(detail: error.toString()));
    }
  }

  Future<Result<void>> deleteFolder({
    required int accountId,
    required int mailboxId,
  }) async {
    try {
      final all = await _db.mailboxesOf(accountId);
      final mailbox = all.where((m) => m.id == mailboxId).firstOrNull;
      if (mailbox == null) return const Err(MailboxNotFoundFailure());
      if (mailbox.specialUse != SpecialUse.custom) {
        return const Err(SystemFolderProtectedFailure());
      }
      final prefix = '${mailbox.path}${mailbox.delimiter}';
      if (all.any((m) => m.id != mailboxId && m.path.startsWith(prefix))) {
        return const Err(FolderHasChildrenFailure());
      }
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
    } on Object catch (error) {
      return Err(StorageFailure(detail: error.toString()));
    }
  }

  String? _parentPath(MailboxRow mailbox) {
    final delimiter = mailbox.delimiter;
    if (delimiter.isEmpty) return null;
    final index = mailbox.path.lastIndexOf(delimiter);
    if (index <= 0) return null;
    return mailbox.path.substring(0, index);
  }
}
