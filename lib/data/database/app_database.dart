import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// Liste satırı için birleşik sonuç.
class MessageListItem {
  const MessageListItem({required this.message, required this.labelNames});

  final MessageRow message;
  final List<String> labelNames;
}

@DriftDatabase(
  tables: [
    Accounts,
    Mailboxes,
    Messages,
    MessageBodies,
    Attachments,
    Labels,
    PendingOperations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'kaydet'));

  /// Testler için bellek içi örnek.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
      await _createFtsTable();
    },
    onUpgrade: (m, from, to) async {
      // v1 → v2: OAuth girişi (Gmail) için hesabın kimlik doğrulama
      // biçimini ayırt eden sütun eklendi. Mevcut hesaplar `password`
      // (0) ile devam eder — şifreleri zaten çalışıyordu, davranış
      // değişmez.
      if (from < 2) {
        await m.addColumn(accounts, accounts.authMethod);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // Uzun senkronizasyon işlemlerinde okuma kilitlenmesini önler.
      await customStatement('PRAGMA journal_mode = WAL');
      if (details.wasCreated) return;
      await _createIndexes();
      await _createFtsTable();
    },
  );

  Future<void> _createIndexes() async {
    // Liste sorgusunun tamamı bu indeksten okunur.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_list '
      'ON messages (account_id, mailbox_id, date_utc DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages (thread_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_flagged '
      'ON messages (account_id, is_flagged)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_msgid '
      'ON messages (message_id_header)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_outbox '
      'ON messages (account_id, outbox_state)',
    );
    // UID benzersizliği yalnızca sunucu kaynaklı iletiler için geçerlidir;
    // yerel taslak/giden kutusu kayıtlarında uid NULL olur.
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_uid '
      'ON messages (account_id, mailbox_id, uid) WHERE uid IS NOT NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attachments_message '
      'ON attachments (message_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_pending_status '
      'ON pending_operations (account_id, status, next_attempt_at)',
    );
  }

  /// Tam metin arama tablosu.
  ///
  /// İçeriğe yazılan metin `foldForSearch()` ile normalleştirilmiştir; sorgu
  /// da aynı fonksiyondan geçer. Böylece "sahan" araması "Şahan"ı bulur.
  Future<void> _createFtsTable() async {
    await customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5("
      "content, message_id UNINDEXED, "
      "tokenize=\"unicode61 remove_diacritics 2\")",
    );
  }

  // ---------------------------------------------------------------- hesaplar

  Future<List<AccountRow>> allAccounts() => (select(
    accounts,
  )..orderBy([(a) => OrderingTerm(expression: a.id)])).get();

  /// Hesap değiştirici listesi: eklenme sırasına göre, kalıcı bir sıra.
  Stream<List<AccountRow>> watchAllAccounts() => (select(
    accounts,
  )..orderBy([(a) => OrderingTerm(expression: a.id)])).watch();

  /// Aktif hesap her zaman tekildir (hesap değiştirici modeli); birden
  /// fazla satır `isActive=true` olursa (olmamalı) en küçük id kazanır.
  Stream<AccountRow?> watchActiveAccount() =>
      (select(accounts)
            ..where((a) => a.isActive.equals(true))
            ..orderBy([(a) => OrderingTerm(expression: a.id)])
            ..limit(1))
          .watchSingleOrNull();

  Future<AccountRow?> activeAccount() =>
      (select(accounts)
            ..where((a) => a.isActive.equals(true))
            ..orderBy([(a) => OrderingTerm(expression: a.id)])
            ..limit(1))
          .getSingleOrNull();

  Future<AccountRow?> accountById(int id) =>
      (select(accounts)..where((a) => a.id.equals(id))).getSingleOrNull();

  Future<int> insertAccount(AccountsCompanion account) =>
      into(accounts).insert(account);

  Future<void> updateAccountFields(int id, AccountsCompanion patch) =>
      (update(accounts)..where((a) => a.id.equals(id))).write(patch);

  /// Tüm hesapları pasifleştirir. Hesap değiştirirken/eklerken, yeni hesap
  /// etkinleşmeden önce çağrılır — aksi hâlde iki hesap aynı anda
  /// `isActive=true` olabilir ve hangisinin gösterileceği belirsizleşir.
  Future<void> deactivateAllAccounts() =>
      update(accounts).write(const AccountsCompanion(isActive: Value(false)));

  /// Tek bir hesabı etkinleştirir; diğerleri aynı işlemde pasifleşir.
  ///
  /// [deactivateAllAccounts] + ayrı bir `updateAccountFields` çağrısı iki
  /// ayrı yazma olduğundan aralarında kısa bir an hiçbir hesap etkin
  /// değildir; `watchActiveAccount()` bu anı `null` olarak yayınlar ve
  /// uygulamanın kökü (bkz. `app.dart`) bunu "hesap yok" sanıp anlık olarak
  /// Giriş ekranına düşer. Tek işlemde yapmak bu aralığı tamamen kapatır.
  Future<void> activateAccount(int accountId) => transaction(() async {
    await deactivateAllAccounts();
    await updateAccountFields(
      accountId,
      const AccountsCompanion(isActive: Value(true)),
    );
  });

  Future<void> deleteAccount(int id) =>
      (delete(accounts)..where((a) => a.id.equals(id))).go();

  // --------------------------------------------------------------- klasörler

  Stream<List<MailboxRow>> watchMailboxes(int accountId) =>
      (select(mailboxes)
            ..where((m) => m.accountId.equals(accountId))
            ..orderBy([
              (m) => OrderingTerm(expression: m.sortOrder),
              (m) => OrderingTerm(expression: m.name),
            ]))
          .watch();

  Future<List<MailboxRow>> mailboxesOf(int accountId) =>
      (select(mailboxes)
            ..where((m) => m.accountId.equals(accountId))
            ..orderBy([(m) => OrderingTerm(expression: m.sortOrder)]))
          .get();

  Future<MailboxRow?> mailboxById(int id) =>
      (select(mailboxes)..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<MailboxRow?> mailboxByPath(int accountId, String path) =>
      (select(mailboxes)
            ..where((m) => m.accountId.equals(accountId) & m.path.equals(path)))
          .getSingleOrNull();

  Future<MailboxRow?> mailboxBySpecialUse(int accountId, SpecialUse use) =>
      (select(mailboxes)
            ..where(
              (m) =>
                  m.accountId.equals(accountId) & m.specialUse.equalsValue(use),
            )
            ..limit(1))
          .getSingleOrNull();

  Future<int> upsertMailbox(MailboxesCompanion row) async {
    final existing = await mailboxByPath(row.accountId.value, row.path.value);
    if (existing == null) {
      return into(mailboxes).insert(row);
    }
    await (update(mailboxes)..where((m) => m.id.equals(existing.id))).write(
      row.copyWith(id: const Value.absent()),
    );
    return existing.id;
  }

  Future<void> updateMailboxSync(
    int mailboxId, {
    int? uidValidity,
    int? uidNext,
    int? highestModSeq,
    int? totalCount,
    bool? hasMoreOnServer,
    DateTime? lastSyncAt,
  }) => (update(mailboxes)..where((m) => m.id.equals(mailboxId))).write(
    MailboxesCompanion(
      uidValidity: uidValidity == null
          ? const Value.absent()
          : Value(uidValidity),
      uidNext: uidNext == null ? const Value.absent() : Value(uidNext),
      highestModSeq: highestModSeq == null
          ? const Value.absent()
          : Value(highestModSeq),
      totalCount: totalCount == null ? const Value.absent() : Value(totalCount),
      hasMoreOnServer: hasMoreOnServer == null
          ? const Value.absent()
          : Value(hasMoreOnServer),
      lastSyncAt: lastSyncAt == null ? const Value.absent() : Value(lastSyncAt),
    ),
  );

  /// UIDVALIDITY değiştiğinde klasörün tüm yerel içeriğini siler.
  ///
  /// Yerel (henüz gönderilmemiş) iletiler korunur — onların sunucuda
  /// karşılığı yoktur ve kaybolmaları veri kaybı demektir.
  Future<void> purgeMailboxMessages(int mailboxId) async {
    final ids =
        await (select(messages)..where(
              (m) =>
                  m.mailboxId.equals(mailboxId) & m.isLocalOnly.equals(false),
            ))
            .map((m) => m.id)
            .get();
    if (ids.isEmpty) return;
    // FTS silme + satır silme tek transaction'da: kesinti anında FTS
    // girdileri silinip mesaj satırları kalması gibi bir tutarsızlığı önler.
    await transaction(() async {
      await _deleteFtsFor(ids);
      await (delete(messages)..where((m) => m.id.isIn(ids))).go();
    });
  }

  // ----------------------------------------------------------------- iletiler

  /// Klasördeki iletiler, tarihe göre yeniden eskiye.
  Stream<List<MessageRow>> watchMessages({
    required int accountId,
    required int mailboxId,
    int limit = 100,
  }) =>
      (select(messages)
            ..where(
              (m) =>
                  m.accountId.equals(accountId) &
                  m.mailboxId.equals(mailboxId) &
                  m.isDeleted.equals(false),
            )
            ..orderBy([
              (m) =>
                  OrderingTerm(expression: m.dateUtc, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .watch();

  /// Sanal "Sabitlenenler" klasörü — IMAP `\Flagged` bayrağı.
  Stream<List<MessageRow>> watchFlagged({
    required int accountId,
    int limit = 200,
  }) =>
      (select(messages)
            ..where(
              (m) =>
                  m.accountId.equals(accountId) &
                  m.isFlagged.equals(true) &
                  m.isDeleted.equals(false),
            )
            ..orderBy([
              (m) =>
                  OrderingTerm(expression: m.dateUtc, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .watch();

  Future<MessageRow?> messageById(int id) =>
      (select(messages)..where((m) => m.id.equals(id))).getSingleOrNull();

  Stream<MessageRow?> watchMessageById(int id) =>
      (select(messages)..where((m) => m.id.equals(id))).watchSingleOrNull();

  Future<MessageRow?> messageByUid(int mailboxId, int uid) =>
      (select(messages)
            ..where((m) => m.mailboxId.equals(mailboxId) & m.uid.equals(uid)))
          .getSingleOrNull();

  Future<List<MessageRow>> messagesByIds(List<int> ids) =>
      (select(messages)..where((m) => m.id.isIn(ids))).get();

  /// Klasördeki sunucu kaynaklı UID'ler.
  ///
  /// Yalnızca `uid` sütunu projekte edilir. Büyük bir klasörde (100K+ mesaj)
  /// her senkronizasyon turunda tüm satırı (~25 sütun: subject, preview,
  /// toAddrJson...) tam `MessageRow` nesnesi olarak belleğe çekmek yerine
  /// yalnızca ihtiyaç duyulan tek sütunu okur — bu metot her senkronizasyonda
  /// (`_syncDeletions`, CONDSTORE'suz `_syncFlags`) çağrılır.
  Future<List<int>> uidsOf(int mailboxId) async {
    final rows =
        await (selectOnly(messages)
              ..addColumns([messages.uid])
              ..where(
                messages.mailboxId.equals(mailboxId) & messages.uid.isNotNull(),
              ))
            .get();
    return rows.map((r) => r.read(messages.uid)!).toList();
  }

  Future<int?> lowestUid(int mailboxId) async {
    final row =
        await (select(messages)
              ..where((m) => m.mailboxId.equals(mailboxId) & m.uid.isNotNull())
              ..orderBy([(m) => OrderingTerm(expression: m.uid)])
              ..limit(1))
            .getSingleOrNull();
    return row?.uid;
  }

  Future<int?> highestUid(int mailboxId) async {
    final row =
        await (select(messages)
              ..where((m) => m.mailboxId.equals(mailboxId) & m.uid.isNotNull())
              ..orderBy([
                (m) => OrderingTerm(expression: m.uid, mode: OrderingMode.desc),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row?.uid;
  }

  Future<int> countMessages(int mailboxId) async {
    final count = countAll();
    final row =
        await (selectOnly(messages)
              ..addColumns([count])
              ..where(messages.mailboxId.equals(mailboxId)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> countUnread(int mailboxId) async {
    final count = countAll();
    final row =
        await (selectOnly(messages)
              ..addColumns([count])
              ..where(
                messages.mailboxId.equals(mailboxId) &
                    messages.isSeen.equals(false) &
                    messages.isDeleted.equals(false),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> countFlagged(int accountId) async {
    final count = countAll();
    final row =
        await (selectOnly(messages)
              ..addColumns([count])
              ..where(
                messages.accountId.equals(accountId) &
                    messages.isFlagged.equals(true) &
                    messages.isDeleted.equals(false),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Sunucudan gelen iletileri yazar; var olanı günceller.
  ///
  /// Dönüş: yeni eklenen iletilerin yerel kimlikleri (bildirim için).
  Future<List<int>> upsertServerMessages(List<MessagesCompanion> rows) async {
    if (rows.isEmpty) return const [];
    final inserted = <int>[];

    await transaction(() async {
      for (final row in rows) {
        final uid = row.uid.value;
        final mailboxId = row.mailboxId.value;
        MessageRow? existing;
        if (uid != null) {
          existing = await messageByUid(mailboxId, uid);
        }
        if (existing == null) {
          final id = await into(messages).insert(row);
          inserted.add(id);
          await _writeFts(id, row);
        } else {
          await (update(messages)..where((m) => m.id.equals(existing!.id)))
              .write(row.copyWith(id: const Value.absent()));
          await _writeFts(existing.id, row);
        }
      }
    });

    return inserted;
  }

  Future<int> insertLocalMessage(MessagesCompanion row) async {
    final id = await into(messages).insert(row);
    await _writeFts(id, row);
    return id;
  }

  Future<void> updateMessage(int id, MessagesCompanion patch) async {
    await (update(messages)..where((m) => m.id.equals(id))).write(patch);
  }

  Future<void> updateMessages(List<int> ids, MessagesCompanion patch) async {
    if (ids.isEmpty) return;
    await (update(messages)..where((m) => m.id.isIn(ids))).write(patch);
  }

  /// Yalnızca ileti henüz gönderilmediyse "gönderiliyor" durumuna geçirir.
  ///
  /// Dönüş 0 ise ileti az önce başka bir işlemci tarafından zaten
  /// gönderilmiş demektir (bkz. `claimDueOperations` — arka plan
  /// senkronizasyonu ayrı bir isolate'ta çalıştığından aynı `send` işlemi
  /// teorik olarak iki işlemci tarafından eşzamanlı sahiplenebilir);
  /// çağıran bu durumda göndermeyi ATLAMALIDIR, aksi hâlde alıcı aynı
  /// e-postayı iki kez alır. Koşullu `UPDATE ... WHERE outboxState != sent`
  /// bunu tek bir atomik SQL ifadesiyle garanti eder.
  Future<int> claimOutboxSend(int messageId) =>
      (update(messages)..where(
            (m) =>
                m.id.equals(messageId) &
                m.outboxState.isIn([
                  OutboxState.none.index,
                  OutboxState.queued.index,
                  OutboxState.sending.index,
                  OutboxState.failed.index,
                ]),
          ))
          .write(
            const MessagesCompanion(outboxState: Value(OutboxState.sending)),
          );

  Future<void> deleteMessages(List<int> ids) async {
    if (ids.isEmpty) return;
    await transaction(() async {
      await _deleteFtsFor(ids);
      await (delete(messages)..where((m) => m.id.isIn(ids))).go();
    });
  }

  Future<void> deleteMessagesByUid(int mailboxId, List<int> uids) async {
    if (uids.isEmpty) return;
    final rows = await (select(
      messages,
    )..where((m) => m.mailboxId.equals(mailboxId) & m.uid.isIn(uids))).get();
    await deleteMessages(rows.map((r) => r.id).toList());
  }

  /// Giden kutusundaki iletiler (gönderilmeyi bekleyen).
  Stream<List<MessageRow>> watchOutbox(int accountId) =>
      (select(messages)
            ..where(
              (m) =>
                  m.accountId.equals(accountId) &
                  m.outboxState.isIn([
                    OutboxState.queued.index,
                    OutboxState.sending.index,
                    OutboxState.failed.index,
                  ]),
            )
            ..orderBy([(m) => OrderingTerm(expression: m.dateUtc)]))
          .watch();

  Future<List<MessageRow>> pendingOutbox(int accountId) =>
      (select(messages)
            ..where(
              (m) =>
                  m.accountId.equals(accountId) &
                  m.outboxState.isIn([
                    OutboxState.queued.index,
                    OutboxState.failed.index,
                  ]),
            )
            ..orderBy([(m) => OrderingTerm(expression: m.dateUtc)]))
          .get();

  // ------------------------------------------------------------------ gövde

  Future<MessageBodyRow?> bodyOf(int messageId) => (select(
    messageBodies,
  )..where((b) => b.messageId.equals(messageId))).getSingleOrNull();

  Stream<MessageBodyRow?> watchBody(int messageId) => (select(
    messageBodies,
  )..where((b) => b.messageId.equals(messageId))).watchSingleOrNull();

  Future<void> upsertBody({
    required int messageId,
    String? plainText,
    String? html,
  }) async {
    await into(messageBodies).insertOnConflictUpdate(
      MessageBodiesCompanion.insert(
        messageId: Value(messageId),
        plainText: Value(plainText),
        html: Value(html),
        fetchedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await (update(messages)..where((m) => m.id.equals(messageId))).write(
      MessagesCompanion(bodyFetchedAt: Value(DateTime.now().toUtc())),
    );
    // Gövde geldiğinde arama indeksi zenginleşir.
    final message = await messageById(messageId);
    if (message != null) {
      await _rebuildFtsForMessage(message, plainText ?? '');
    }
  }

  /// 30 günden eski gövdeleri budar; envelope kaydı kalır.
  Future<int> pruneOldBodies({Duration keep = const Duration(days: 30)}) async {
    final cutoff = DateTime.now().toUtc().subtract(keep);
    return (delete(
      messageBodies,
    )..where((b) => b.fetchedAt.isSmallerThanValue(cutoff))).go();
  }

  // ------------------------------------------------------------------ ekler

  Future<List<AttachmentRow>> attachmentsOf(int messageId) =>
      (select(attachments)..where((a) => a.messageId.equals(messageId))).get();

  Stream<List<AttachmentRow>> watchAttachments(int messageId) => (select(
    attachments,
  )..where((a) => a.messageId.equals(messageId))).watch();

  Future<void> replaceAttachments(
    int messageId,
    List<AttachmentsCompanion> rows,
  ) async {
    await transaction(() async {
      await (delete(attachments)..where(
            (a) => a.messageId.equals(messageId) & a.isOutgoing.equals(false),
          ))
          .go();
      for (final row in rows) {
        await into(attachments).insert(row);
      }
    });
  }

  Future<int> addAttachment(AttachmentsCompanion row) =>
      into(attachments).insert(row);

  Future<void> setAttachmentPath(int id, String path) =>
      (update(attachments)..where((a) => a.id.equals(id))).write(
        AttachmentsCompanion(localPath: Value(path)),
      );

  Future<void> removeAttachment(int id) =>
      (delete(attachments)..where((a) => a.id.equals(id))).go();

  // --------------------------------------------------------------- etiketler

  Stream<List<LabelRow>> watchLabels(int accountId) =>
      (select(labels)
            ..where((l) => l.accountId.equals(accountId))
            ..orderBy([(l) => OrderingTerm(expression: l.name)]))
          .watch();

  Future<List<LabelRow>> labelsOf(int accountId) =>
      (select(labels)..where((l) => l.accountId.equals(accountId))).get();

  Future<int> insertLabel(LabelsCompanion row) =>
      into(labels).insertOnConflictUpdate(row);

  Future<void> deleteLabel(int id) =>
      (delete(labels)..where((l) => l.id.equals(id))).go();

  // ------------------------------------------------------------------ kuyruk

  Future<int> enqueue(PendingOperationsCompanion row) =>
      into(pendingOperations).insert(row);

  Future<List<PendingOperationRow>> dueOperations(
    int accountId, {
    int limit = 50,
  }) {
    final now = DateTime.now().toUtc();
    return (select(pendingOperations)
          ..where(
            (p) =>
                p.accountId.equals(accountId) &
                p.status.equalsValue(PendingOpStatus.pending) &
                (p.nextAttemptAt.isNull() |
                    p.nextAttemptAt.isSmallerOrEqualValue(now)),
          )
          ..orderBy([(p) => OrderingTerm(expression: p.createdAt)])
          ..limit(limit))
        .get();
  }

  /// Kuyruk zamanlaması (backoff) ne olursa olsun, henüz kalıcı hataya
  /// düşmemiş (terminal olmayan) tüm işlemler.
  ///
  /// [SyncEngine]'in "bu UID'de bekleyen bir kullanıcı işlemi var, sunucudan
  /// gelen eski bayrak durumunu üzerine yazma" kilidi için kullanılır.
  /// [dueOperations]'ın aksine `nextAttemptAt` filtresi UYGULANMAZ: geri
  /// çekilme (backoff) bekleyen bir işlem de kilit altında kalmalıdır, aksi
  /// hâlde tam bu pencerede kullanıcının değişikliği sessizce geri alınabilir.
  Future<List<PendingOperationRow>> activeOperations(
    int accountId, {
    int limit = 200,
  }) {
    return (select(pendingOperations)
          ..where(
            (p) =>
                p.accountId.equals(accountId) &
                p.status.isIn([
                  PendingOpStatus.pending.index,
                  PendingOpStatus.running.index,
                ]),
          )
          ..orderBy([(p) => OrderingTerm(expression: p.createdAt)])
          ..limit(limit))
        .get();
  }

  /// Bir sahiplenmenin ("running") en fazla ne kadar süre geçerli sayılacağı.
  ///
  /// Sahiplenen işlemci bu süre içinde tamamlamaz/başarısız saymazsa (örn.
  /// çökme), işlem `claimDueOperations` tarafından yeniden sahiplenilebilir
  /// hâle gelir — aksi hâlde `running` durumunda sonsuza dek asılı kalırdı.
  static const Duration _claimLease = Duration(minutes: 3);

  static bool _isClaimable(PendingOperationRow op, DateTime now) {
    switch (op.status) {
      case PendingOpStatus.pending:
        return op.nextAttemptAt == null || !op.nextAttemptAt!.isAfter(now);
      case PendingOpStatus.running:
        return op.nextAttemptAt != null && !op.nextAttemptAt!.isAfter(now);
      case PendingOpStatus.failed:
      case PendingOpStatus.done:
        return false;
    }
  }

  Expression<bool> _nextAttemptMatches(
    $PendingOperationsTable p,
    DateTime? value,
  ) => value == null ? p.nextAttemptAt.isNull() : p.nextAttemptAt.equals(value);

  /// Bekleyen işlemleri sunucuya uygulamak üzere ATOMİK olarak sahiplenir.
  ///
  /// [dueOperations] yalnızca SELECT yapar; aynı satır iki farklı işlemci
  /// (örn. ön plandaki kullanıcı eylemi + WorkManager'ın ayrı isolate'ta
  /// çalışan arka plan senkronizasyonu — ikisi de aynı sqlite dosyasını
  /// paylaşır) tarafından eşzamanlı okunup İKİ KEZ işlenebilir; bu özellikle
  /// `send` işleminde alıcının aynı e-postayı iki kez alması demektir.
  ///
  /// Bu metot her adayı `WHERE id=? AND status=? AND next_attempt_at=?`
  /// koşullu tek bir `UPDATE` ile "kilitler" — koşul, adayı SELECT ederken
  /// okunan tam (status, nextAttemptAt) çiftiyle eşleşmelidir. SQLite aynı
  /// satıra yazan iki `UPDATE`'i sıraya koyduğundan, ikinci çağrının WHERE
  /// koşulu (satır artık ilk çağrı tarafından değiştirildiği için) eşleşmez
  /// ve 0 satır etkiler — bu, süreçler/isolate'lar arası doğru çalışan bir
  /// "compare-and-swap" sağlar. Kazanan `status`'u `running`'e çevirir ve
  /// `nextAttemptAt`'ı bir kira (lease) süresi kadar ileri atar.
  Future<List<PendingOperationRow>> claimDueOperations(
    int accountId, {
    int limit = 50,
  }) async {
    final now = DateTime.now().toUtc();
    final candidates = await activeOperations(accountId, limit: limit);
    final leaseUntil = now.add(_claimLease);

    final claimed = <PendingOperationRow>[];
    for (final op in candidates) {
      if (!_isClaimable(op, now)) continue;
      final affected =
          await (update(pendingOperations)..where(
                (p) =>
                    p.id.equals(op.id) &
                    p.status.equalsValue(op.status) &
                    _nextAttemptMatches(p, op.nextAttemptAt),
              ))
              .write(
                PendingOperationsCompanion(
                  status: const Value(PendingOpStatus.running),
                  nextAttemptAt: Value(leaseUntil),
                ),
              );
      if (affected > 0) claimed.add(op);
    }
    return claimed;
  }

  /// Sahiplenilmiş (`running`) işlemleri hiçbir deneme sayısı artırmadan
  /// `pending`'e geri döndürür.
  ///
  /// Örn. bağlantı kurulamadığı için sahiplenilen işlemlerin hiçbiri
  /// gerçekten denenmediğinde kullanılır — aksi hâlde bu işlemler
  /// sahiplenme kirası (bkz. `_claimLease`) dolana kadar görünmez kalır ve
  /// ağ geri geldiğinde gereksiz yere birkaç dakika gecikirdi.
  Future<void> releaseOperations(List<int> ids) async {
    if (ids.isEmpty) return;
    await (update(pendingOperations)..where((p) => p.id.isIn(ids))).write(
      const PendingOperationsCompanion(
        status: Value(PendingOpStatus.pending),
        nextAttemptAt: Value(null),
      ),
    );
  }

  Stream<int> watchPendingCount(int accountId) {
    final count = countAll();
    return (selectOnly(pendingOperations)
          ..addColumns([count])
          ..where(
            pendingOperations.accountId.equals(accountId) &
                pendingOperations.status.equalsValue(PendingOpStatus.pending),
          ))
        .map((row) => row.read(count) ?? 0)
        .watchSingle();
  }

  Future<void> completeOperation(int id) =>
      (delete(pendingOperations)..where((p) => p.id.equals(id))).go();

  Future<void> failOperation(
    int id, {
    required String error,
    required int attemptCount,
    DateTime? nextAttemptAt,
    bool permanent = false,
  }) => (update(pendingOperations)..where((p) => p.id.equals(id))).write(
    PendingOperationsCompanion(
      lastError: Value(error),
      attemptCount: Value(attemptCount),
      nextAttemptAt: Value(nextAttemptAt),
      status: Value(
        permanent ? PendingOpStatus.failed : PendingOpStatus.pending,
      ),
    ),
  );

  // ------------------------------------------------------------------ arama

  /// FTS5 üzerinden arama; sonuç ileti kimlikleri, alaka sırasına göre.
  Future<List<int>> searchMessageIds({
    required int accountId,
    required String query,
    int limit = 200,
  }) async {
    final match = buildFtsQuery(query);
    if (match == null) return const [];
    final rows = await customSelect(
      'SELECT f.message_id AS mid FROM messages_fts f '
      'JOIN messages m ON m.id = f.message_id '
      'WHERE messages_fts MATCH ? AND m.account_id = ? '
      'ORDER BY rank LIMIT ?',
      variables: [
        Variable<String>(match),
        Variable<int>(accountId),
        Variable<int>(limit),
      ],
      readsFrom: {messages},
    ).get();
    return rows.map((r) => r.read<int>('mid')).toList();
  }

  /// Kullanıcı girdisini güvenli bir FTS5 sorgusuna çevirir.
  ///
  /// FTS5'te `"`, `*`, `-`, `(` gibi karakterler operatördür; ham metin
  /// doğrudan verilirse sorgu sözdizimi hatası fırlatır ve arama çöker.
  /// Her sözcük tırnak içine alınır, sonuna önek eşleme (`*`) eklenir.
  static String? buildFtsQuery(String raw) {
    final folded = foldForSearch(raw).trim();
    if (folded.isEmpty) return null;
    final tokens = folded
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;
    return tokens.map((t) => '"${t.replaceAll('"', '')}"*').join(' ');
  }

  String _ftsContentFor(MessagesCompanion row, [String body = '']) {
    final parts = <String>[
      row.subject.present ? row.subject.value : '',
      row.fromName.present ? row.fromName.value : '',
      row.fromEmail.present ? row.fromEmail.value : '',
      row.preview.present ? row.preview.value : '',
      body,
    ];
    return foldForSearch(parts.where((p) => p.isNotEmpty).join(' '));
  }

  Future<void> _writeFts(int messageId, MessagesCompanion row) async {
    await customStatement('DELETE FROM messages_fts WHERE message_id = ?', [
      messageId,
    ]);
    await customStatement(
      'INSERT INTO messages_fts (content, message_id) VALUES (?, ?)',
      [_ftsContentFor(row), messageId],
    );
  }

  Future<void> _rebuildFtsForMessage(MessageRow row, String body) async {
    final content = foldForSearch(
      [
        row.subject,
        row.fromName,
        row.fromEmail,
        row.preview,
        body,
      ].where((p) => p.isNotEmpty).join(' '),
    );
    await customStatement('DELETE FROM messages_fts WHERE message_id = ?', [
      row.id,
    ]);
    await customStatement(
      'INSERT INTO messages_fts (content, message_id) VALUES (?, ?)',
      [content, row.id],
    );
  }

  Future<void> _deleteFtsFor(List<int> ids) async {
    for (final id in ids) {
      await customStatement('DELETE FROM messages_fts WHERE message_id = ?', [
        id,
      ]);
    }
  }

  /// Hesap silindiğinde her şeyi temizler.
  Future<void> wipeAccount(int accountId) async {
    final ids = await (select(
      messages,
    )..where((m) => m.accountId.equals(accountId))).map((m) => m.id).get();
    await transaction(() async {
      await _deleteFtsFor(ids);
      await deleteAccount(accountId);
    });
  }
}
