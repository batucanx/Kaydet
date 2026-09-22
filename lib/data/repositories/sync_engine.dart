import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../../domain/use_cases/text_extraction.dart';
import '../../domain/use_cases/threading.dart';
import '../database/app_database.dart';
import 'mail_connection.dart';

/// Senkronizasyon sonucu.
class SyncOutcome {
  const SyncOutcome({
    this.newMessageIds = const [],
    this.changedCount = 0,
    this.deletedCount = 0,
    this.resynced = false,
    this.initialDownload = false,
  });

  final List<int> newMessageIds;
  final int changedCount;
  final int deletedCount;

  /// UIDVALIDITY değiştiği için klasör baştan indirildi mi?
  final bool resynced;

  /// Klasör bu turda ilk kez (ya da baştan) indirildi mi? Bu durumda
  /// [newMessageIds] "yeni gelen" değil, mevcut iletilerdir — bildirim
  /// üretilmemeli, yoksa yeni eklenen bir hesap geçmiş iletiler için
  /// bildirim yağdırır.
  final bool initialDownload;

  /// Değişiklik (yeni/silinen/bayrağı değişen ileti) var mı?
  bool get hasChanges =>
      newMessageIds.isNotEmpty ||
      changedCount > 0 ||
      deletedCount > 0 ||
      initialDownload;
}

/// IMAP ↔ yerel veritabanı eşitlemesi.
class SyncEngine {
  SyncEngine({
    required AppDatabase database,
    required MailConnection connection,
  }) : _db = database,
       _connection = connection;

  final AppDatabase _db;
  final MailConnection _connection;

  /// İlk açılışta çekilen ileti sayısı.
  static const int initialFetchCount = 50;

  /// "Daha fazla yükle" sayfası.
  static const int pageSize = 50;

  /// Bayrak karşılaştırması için pencere (CONDSTORE yoksa).
  static const int flagWindow = 500;

  /// Arka planda önizleme için gövdesi çekilecek ileti sayısı.
  static const int bodyPrefetchCount = 25;

  /// Bu boyutun altındaki HTML gövdeler doğrudan bu isolate'te temizlenir.
  ///
  /// `TextExtraction.htmlToPlain` regex tabanlıdır (DOM ayrıştırmaz) ve
  /// küçük/orta gövdelerde isolate açmanın kendisi işin maliyetinden daha
  /// pahalıdır. Büyük bülten/pazarlama e-postalarında (yüzlerce KB, derin
  /// iç içe tablo) regex geçişleri kare bütçesini (16 ms) aşabilir — bu
  /// senkronizasyon `unawaited` çalışsa bile AYNI isolate'te yürüdüğü için
  /// ana thread'in kare çizimini yine çalar; eşik üstündekiler ayrı
  /// isolate'e taşınır.
  static const int _htmlIsolateThreshold = 20000;

  // ------------------------------------------------------------- klasörler

  /// Sunucudaki klasörleri yerel veritabanıyla eşitler.
  Future<Result<List<MailboxRow>>> syncMailboxes(int accountId) async {
    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final listed = await _connection.imap.listMailboxes();
    if (listed is Err<List<RemoteMailbox>>) return Err(listed.failure);
    final remote = (listed as Ok<List<RemoteMailbox>>).value;

    // Her tür (Gelen Kutusu, İstenmeyen, …) bir hesapta tek klasöre ait
    // olmalı. Bazı sunucular aynı türe eşlenen birden çok klasör sunar
    // (ör. hem "Junk" hem "Bulk Mail" adında iki klasör) — bu durumda
    // sunucunun SPECIAL-USE bayrağıyla işaretlediği kazanır, yoksa listede
    // önce gelen; kaybeden klasör kendi gerçek adıyla normal bir klasör
    // olarak kalır. Aksi hâlde yan menüde aynı adla iki klasör görünür.
    final resolvedUses = <String, SpecialUse>{};
    final claimedBy = <SpecialUse, String>{};
    for (final box in remote) {
      final use = FolderMapping.resolve(
        path: box.path,
        delimiter: box.delimiter,
        serverFlagUse: box.specialUse,
      );
      resolvedUses[box.path] = use;
      if (use == SpecialUse.custom) continue;

      final claimant = claimedBy[use];
      if (claimant == null) {
        claimedBy[use] = box.path;
      } else if (box.specialUse == use) {
        // Bu klasör sunucu tarafından açıkça bu türle işaretli: önceki
        // (yalnızca ad eşleşmesiyle kazanan) iddiacıdan türü geri alır.
        resolvedUses[claimant] = SpecialUse.custom;
        claimedBy[use] = box.path;
      } else {
        resolvedUses[box.path] = SpecialUse.custom;
      }
    }

    final seenPaths = <String>{};
    for (final box in remote) {
      final use = resolvedUses[box.path]!;
      final leaf = FolderMapping.leafName(box.path, box.delimiter);
      await _db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: box.path,
          name: FolderMapping.displayName(use, leaf),
          encodedPath: Value(box.encodedPath),
          specialUse: Value(use),
          delimiter: Value(box.delimiter),
          isSubscribed: Value(box.isSubscribed),
          isSelectable: Value(box.isSelectable),
          sortOrder: Value(FolderMapping.sortOrderFor(use)),
        ),
      );
      seenPaths.add(box.path);
    }

    // Sunucudan kaldırılmış klasörleri yerelden de sil.
    final local = await _db.mailboxesOf(accountId);
    for (final row in local) {
      if (!seenPaths.contains(row.path)) {
        await _db.purgeMailboxMessages(row.id);
      }
    }

    return Ok(await _db.mailboxesOf(accountId));
  }

  // -------------------------------------------------------------- iletiler

  /// Bir klasörü eşitler.
  Future<Result<SyncOutcome>> syncMailbox({
    required int accountId,
    required MailboxRow mailbox,
  }) async {
    if (!mailbox.isSelectable) return const Ok(SyncOutcome());

    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final caps = _connection.capabilities;
    final selected = await _connection.imap.selectMailbox(
      mailbox.path,
      enableCondStore: caps.supportsCondStore,
    );
    if (selected is Err<MailboxState>) return Err(selected.failure);
    final state = (selected as Ok<MailboxState>).value;

    // Sunucu özel anahtar kelime (etiket) destekliyor mu? Bir kez öğrenilir.
    await _recordKeywordSupport(accountId, state);

    var resynced = false;

    // --- 1. UIDVALIDITY kontrolü -----------------------------------------
    // Bu kontrol atlanırsa uygulama eski UID'lerle işlem yapar ve YANLIŞ
    // iletiyi siler. Mail istemcilerindeki en tehlikeli hata sınıfıdır.
    if (mailbox.uidValidity != null &&
        mailbox.uidValidity != state.uidValidity) {
      await _db.purgeMailboxMessages(mailbox.id);
      resynced = true;
    }

    await _db.updateMailboxSync(
      mailbox.id,
      uidValidity: state.uidValidity,
      totalCount: state.messageCount,
      lastSyncAt: DateTime.now().toUtc(),
    );

    if (state.messageCount == 0) {
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      return Ok(SyncOutcome(resynced: resynced));
    }

    // --- 2. Yeni iletiler -------------------------------------------------
    final localHighest = await _db.highestUid(mailbox.id);
    List<int> newIds = const [];

    // Yerel kayıt yokluğu tek başına "ilk indirme" demek değildir: kullanıcı
    // tüm iletileri arşivleyip/silip Gelen Kutusu'nu boşaltmış olabilir. Klasör
    // daha önce eşitlendiyse (`uidNext` biliniyor) yalnızca yeni iletiler
    // çekilir ve bildirim bastırılmaz.
    final neverSynced = mailbox.uidNext == null;
    if (resynced || (localHighest == null && neverSynced)) {
      // İlk indirme: en yeni N ileti.
      final all = await _connection.imap.searchAllUids();
      if (all is Err<List<int>>) return Err(all.failure);
      final uids = (all as Ok<List<int>>).value..sort();
      final slice = uids.length <= initialFetchCount
          ? uids
          : uids.sublist(uids.length - initialFetchCount);
      final fetched = await _fetchAndStore(accountId, mailbox, slice);
      if (fetched is Err<List<int>>) return Err(fetched.failure);
      newIds = (fetched as Ok<List<int>>).value;
      await _db.updateMailboxSync(
        mailbox.id,
        uidNext: state.uidNext,
        hasMoreOnServer: uids.length > slice.length,
      );
      return Ok(
        SyncOutcome(
          newMessageIds: newIds,
          resynced: resynced,
          initialDownload: true,
        ),
      );
    }

    final fromUid = localHighest != null
        ? localHighest + 1
        : mailbox.uidNext!;
    if (state.uidNext > fromUid) {
      final fetched = await _fetchRangeAndStore(
        accountId,
        mailbox,
        fromUid: fromUid,
        toUid: state.uidNext - 1,
      );
      if (fetched is Err<List<int>>) return Err(fetched.failure);
      newIds = (fetched as Ok<List<int>>).value;
    }

    // --- 3. Silinenler ve bayrak değişiklikleri ---------------------------
    final deleted = await _syncDeletions(mailbox);
    final changed = await _syncFlags(accountId, mailbox, state, caps);

    await _db.updateMailboxSync(
      mailbox.id,
      uidNext: state.uidNext,
      highestModSeq: state.highestModSeq,
    );

    return Ok(
      SyncOutcome(
        newMessageIds: newIds,
        changedCount: changed,
        deletedCount: deleted,
        resynced: resynced,
      ),
    );
  }

  /// Daha eski iletileri sayfa sayfa indirir.
  Future<Result<int>> loadOlder({
    required int accountId,
    required MailboxRow mailbox,
    int count = pageSize,
  }) async {
    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) return Err(connected.failure);

    final selected = await _connection.imap.selectMailbox(mailbox.path);
    if (selected is Err<MailboxState>) return Err(selected.failure);

    final lowest = await _db.lowestUid(mailbox.id);
    if (lowest == null || lowest <= 1) {
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      return const Ok(0);
    }

    final all = await _connection.imap.searchAllUids();
    if (all is Err<List<int>>) return Err(all.failure);
    final older = ((all as Ok<List<int>>).value..sort())
        .where((uid) => uid < lowest)
        .toList();

    if (older.isEmpty) {
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      return const Ok(0);
    }

    final slice = older.length <= count
        ? older
        : older.sublist(older.length - count);
    final fetched = await _fetchAndStore(accountId, mailbox, slice);
    if (fetched is Err<List<int>>) return Err(fetched.failure);

    await _db.updateMailboxSync(
      mailbox.id,
      hasMoreOnServer: older.length > slice.length,
    );
    return Ok((fetched as Ok<List<int>>).value.length);
  }

  /// Gövdesi olmayan en yeni iletilerin gövdesini arka planda indirir.
  ///
  /// Liste satırındaki özet metni buradan doğar: kısmi gövde çekmek yerine
  /// tam MIME ayrıştırılır, böylece her sunucuda doğru sonuç alınır.
  Future<void> prefetchBodies({
    required int accountId,
    required MailboxRow mailbox,
    int limit = bodyPrefetchCount,
  }) async {
    if (!_connection.isConnected) return;

    final rows =
        await (_db.select(_db.messages)
              ..where(
                (m) =>
                    m.mailboxId.equals(mailbox.id) &
                    m.bodyFetchedAt.isNull() &
                    m.uid.isNotNull(),
              )
              ..orderBy([
                (m) => OrderingTerm(
                  expression: m.dateUtc,
                  mode: OrderingMode.desc,
                ),
              ])
              ..limit(limit))
            .get();
    if (rows.isEmpty) return;

    final selected = await _connection.imap.selectMailbox(mailbox.path);
    if (selected is Err<MailboxState>) return;

    for (final row in rows) {
      final result = await _connection.imap.fetchBody(row.uid!);
      if (result is Err<FetchedBody>) {
        // Tek bir bozuk ileti önizleme akışını durdurmamalı.
        continue;
      }
      await storeBody(row, (result as Ok<FetchedBody>).value);
    }
  }

  /// Gövdeyi ve eklerini veritabanına yazar, önizlemeyi günceller.
  Future<void> storeBody(MessageRow row, FetchedBody body) async {
    final plain =
        body.plainText ??
        (body.html != null ? await _htmlToPlain(body.html!) : null);

    await _db.upsertBody(messageId: row.id, plainText: plain, html: body.html);

    final preview = TextExtraction.buildPreview(plain);
    if (preview.isNotEmpty && preview != row.preview) {
      await _db.updateMessage(
        row.id,
        MessagesCompanion(preview: Value(preview)),
      );
    }

    if (body.attachments.isNotEmpty) {
      await _db.replaceAttachments(
        row.id,
        body.attachments
            .map(
              (a) => AttachmentsCompanion.insert(
                messageId: row.id,
                partId: Value(a.partId),
                fileName: Value(a.fileName),
                mimeType: Value(a.mimeType),
                sizeBytes: Value(a.sizeBytes),
                contentId: Value(a.contentId),
                isInline: Value(a.isInline),
              ),
            )
            .toList(),
      );
      if (!row.hasAttachments) {
        await _db.updateMessage(
          row.id,
          const MessagesCompanion(hasAttachments: Value(true)),
        );
      }
    }
  }

  // ------------------------------------------------------------ iç yardımcı

  Future<String> _htmlToPlain(String html) {
    if (html.length < _htmlIsolateThreshold) {
      return Future.value(TextExtraction.htmlToPlain(html));
    }
    return Isolate.run(() => TextExtraction.htmlToPlain(html));
  }

  Future<void> _recordKeywordSupport(int accountId, MailboxState state) async {
    if (state.permanentFlags.isEmpty) return;
    final account = await _db.accountById(accountId);
    if (account == null || account.supportsKeywords != null) return;
    await _db.updateAccountFields(
      accountId,
      AccountsCompanion(supportsKeywords: Value(state.supportsKeywords)),
    );
  }

  Future<Result<List<int>>> _fetchAndStore(
    int accountId,
    MailboxRow mailbox,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return const Ok(<int>[]);
    final fetched = await _connection.imap.fetchEnvelopes(uids);
    if (fetched is Err<List<FetchedEnvelope>>) return Err(fetched.failure);
    return Ok(
      await _storeEnvelopes(
        accountId,
        mailbox,
        (fetched as Ok<List<FetchedEnvelope>>).value,
      ),
    );
  }

  Future<Result<List<int>>> _fetchRangeAndStore(
    int accountId,
    MailboxRow mailbox, {
    required int fromUid,
    required int toUid,
  }) async {
    final fetched = await _connection.imap.fetchEnvelopeRange(
      fromUid: fromUid,
      toUid: toUid,
    );
    if (fetched is Err<List<FetchedEnvelope>>) return Err(fetched.failure);
    return Ok(
      await _storeEnvelopes(
        accountId,
        mailbox,
        (fetched as Ok<List<FetchedEnvelope>>).value,
      ),
    );
  }

  Future<List<int>> _storeEnvelopes(
    int accountId,
    MailboxRow mailbox,
    List<FetchedEnvelope> envelopes,
  ) async {
    if (envelopes.isEmpty) return const [];

    // Eski → yeni sırala: ata iletiler çocuklarından önce işlensin.
    final sorted = [...envelopes]..sort((a, b) => a.date.compareTo(b.date));
    final threadIds = await _resolveThreadIds(accountId, sorted);

    final companions = <MessagesCompanion>[];
    for (final envelope in sorted) {
      final from = envelope.from;
      companions.add(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: mailbox.id,
          dateUtc: envelope.date,
          uid: Value(envelope.uid),
          messageIdHeader: Value(Threading.normalizeId(envelope.messageId)),
          inReplyTo: Value(Threading.normalizeId(envelope.inReplyTo)),
          referencesRaw: Value(envelope.references),
          threadId: Value(threadIds[envelope.uid] ?? ''),
          fromName: Value(from?.display ?? ''),
          fromEmail: Value(from?.email ?? ''),
          toAddrJson: Value(EmailAddress.encodeList(envelope.to)),
          ccJson: Value(EmailAddress.encodeList(envelope.cc)),
          bccJson: Value(EmailAddress.encodeList(envelope.bcc)),
          subject: Value(envelope.subject),
          subjectNormalized: Value(normalizeSubject(envelope.subject)),
          isSeen: Value(envelope.isSeen),
          isFlagged: Value(envelope.isFlagged),
          isAnswered: Value(envelope.isAnswered),
          isForwarded: Value(envelope.isForwarded),
          isDraft: Value(envelope.isDraft),
          isDeleted: Value(envelope.isDeleted),
          hasAttachments: Value(envelope.hasAttachments),
          sizeBytes: Value(envelope.sizeBytes),
          labelsJson: Value(jsonEncode(envelope.keywords)),
        ),
      );
    }

    final inserted = await _db.upsertServerMessages(companions);

    // Yalnızca Gelen Kutusu: Gereksiz (spam) göndericilerini veya kendi
    // adresimizi (Gönderilenler'in "from"ı) kişi olarak eklemek istemeyiz.
    if (mailbox.specialUse == SpecialUse.inbox) {
      await _captureContactsFromInbox(accountId, sorted);
    }

    return inserted;
  }

  Future<void> _captureContactsFromInbox(
    int accountId,
    List<FetchedEnvelope> envelopes,
  ) async {
    final byEmail = <String, EmailAddress>{};
    for (final envelope in envelopes) {
      final from = envelope.from;
      if (from == null || !from.isValid) continue;
      byEmail[from.email.toLowerCase()] = from;
    }
    for (final address in byEmail.values) {
      await _db.upsertContact(
        accountId: accountId,
        email: address.email,
        name: address.name,
      );
    }
  }

  /// Yeni iletileri var olan konuşmalara bağlar.
  Future<Map<int, String>> _resolveThreadIds(
    int accountId,
    List<FetchedEnvelope> envelopes,
  ) async {
    // 1. Bu partideki tüm referansları topla.
    final referenced = <String>{};
    for (final envelope in envelopes) {
      referenced.addAll(Threading.parseReferences(envelope.references));
      final inReplyTo = Threading.normalizeId(envelope.inReplyTo);
      if (inReplyTo != null) referenced.add(inReplyTo);
    }

    // 2. Veritabanında bu kimliklere sahip iletileri bul.
    final known = <String, String>{};
    if (referenced.isNotEmpty) {
      final rows =
          await (_db.select(_db.messages)..where(
                (m) =>
                    m.accountId.equals(accountId) &
                    m.messageIdHeader.isIn(referenced.toList()),
              ))
              .get();
      for (final row in rows) {
        final id = row.messageIdHeader;
        if (id != null && row.threadId.isNotEmpty) known[id] = row.threadId;
      }
    }

    // 3. Parti içi zincirleri de hesaba katarak ata → konuşma ataması yap.
    final result = <int, String>{};
    for (final envelope in envelopes) {
      final threadId = Threading.resolveThreadId(
        messageId: envelope.messageId,
        inReplyTo: envelope.inReplyTo,
        references: envelope.references,
        subject: envelope.subject,
        knownThreads: known,
      );
      result[envelope.uid] = threadId;
      final own = Threading.normalizeId(envelope.messageId);
      if (own != null) known[own] = threadId;
    }
    return result;
  }

  /// Sunucuda artık olmayan iletileri yerelden siler.
  Future<int> _syncDeletions(MailboxRow mailbox) async {
    final all = await _connection.imap.searchAllUids();
    if (all is Err<List<int>>) return 0;
    final serverUids = (all as Ok<List<int>>).value.toSet();

    final localUids = await _db.uidsOf(mailbox.id);
    final vanished = localUids
        .where((uid) => !serverUids.contains(uid))
        .toList();
    if (vanished.isEmpty) return 0;

    await _db.deleteMessagesByUid(mailbox.id, vanished);
    return vanished.length;
  }

  /// Bayrak değişikliklerini yerele yansıtır.
  ///
  /// Bekleyen yerel işlemi olan iletiler atlanır; aksi hâlde kullanıcının
  /// az önce yaptığı değişiklik sunucudan gelen eski durumla geri alınır
  /// ve arayüzde "geri zıplama" görülür.
  Future<int> _syncFlags(
    int accountId,
    MailboxRow mailbox,
    MailboxState state,
    ServerCapabilities caps,
  ) async {
    final localUids = await _db.uidsOf(mailbox.id);
    if (localUids.isEmpty) return 0;

    final useCondStore =
        caps.supportsCondStore &&
        mailbox.highestModSeq != null &&
        state.highestModSeq != null &&
        state.highestModSeq! > mailbox.highestModSeq!;

    final window = useCondStore
        ? localUids
        : (localUids..sort()).reversed.take(flagWindow).toList();

    final fetched = await _connection.imap.fetchFlags(
      window,
      changedSinceModSeq: useCondStore ? mailbox.highestModSeq : null,
    );
    if (fetched is Err<List<RemoteFlagState>>) return 0;
    final states = (fetched as Ok<List<RemoteFlagState>>).value;
    if (states.isEmpty) return 0;

    final locked = await _lockedUids(accountId, mailbox.id);

    var changed = 0;
    for (final remote in states) {
      if (locked.contains(remote.uid)) continue;
      final row = await _db.messageByUid(mailbox.id, remote.uid);
      if (row == null) continue;

      final isSeen = remote.flags.contains(r'\Seen');
      final isFlagged = remote.flags.contains(r'\Flagged');
      final isAnswered = remote.flags.contains(r'\Answered');
      final isForwarded = remote.flags.any(
        (f) => f.toLowerCase() == r'$forwarded',
      );
      final keywords = remote.flags
          .where((f) => !f.startsWith(r'\') && f.toLowerCase() != r'$forwarded')
          .toList();
      final labelsJson = jsonEncode(keywords);

      if (row.isSeen == isSeen &&
          row.isFlagged == isFlagged &&
          row.isAnswered == isAnswered &&
          row.isForwarded == isForwarded &&
          row.labelsJson == labelsJson) {
        continue;
      }

      await _db.updateMessage(
        row.id,
        MessagesCompanion(
          isSeen: Value(isSeen),
          isFlagged: Value(isFlagged),
          isAnswered: Value(isAnswered),
          isForwarded: Value(isForwarded),
          labelsJson: Value(labelsJson),
        ),
      );
      changed++;
    }
    return changed;
  }

  /// Bekleyen işlem kuyruğundaki iletilerin UID'leri.
  ///
  /// `claimDueOperations` yerine `activeOperations` kullanılır:
  /// `claimDueOperations` yalnızca zamanı GELMİŞ (backoff beklemeyen)
  /// işlemleri döner. Bir işlem geçici hatadan sonra geri çekilme (backoff)
  /// beklerken de kilitli kalmalıdır — aksi hâlde tam bu pencerede araya
  /// giren bir senkronizasyon, sunucudaki eski bayrağı yerelin üzerine
  /// yazıp kullanıcının az önceki değişikliğini sessizce geri alabilir.
  Future<Set<int>> _lockedUids(int accountId, int mailboxId) async {
    final pending = await _db.activeOperations(accountId, limit: 200);
    final locked = <int>{};
    for (final op in pending) {
      try {
        final payload = jsonDecode(op.payloadJson);
        if (payload is! Map<String, dynamic>) continue;
        if (payload['mailboxId'] != mailboxId) continue;
        final uids = payload['uids'];
        if (uids is List) {
          locked.addAll(uids.whereType<int>());
        }
      } on FormatException {
        continue;
      }
    }
    return locked;
  }
}
