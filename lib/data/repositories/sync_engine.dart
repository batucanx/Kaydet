import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' show min;

import 'package:drift/drift.dart';

import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../../domain/use_cases/settings_document.dart';
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
///
/// Sunucuya giden her mantıksal işlem (`SELECT` + komutlar) bağlantının işlem
/// kilidi altında baştan sona çalışır (bkz. `MailConnection`): araya başka bir
/// klasör/hesap seçimi girip UID'leri yanlış yere uygulatamaz.
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

  /// Gövde ön-yüklemesinde işlem kilidinin tek seferde tutulduğu ileti sayısı.
  ///
  /// Kilit iletiler arasında bırakılır ki kullanıcının açtığı ileti (bkz.
  /// `MailRepository.ensureBody`) tüm ön-yüklemenin bitmesini beklemesin;
  /// ama her iletide klasörü yeniden seçmek de gereksiz gidiş-dönüştür.
  static const int _prefetchChunk = 5;

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
  Future<Result<List<MailboxRow>>> syncMailboxes(int accountId) =>
      _connection.exclusive<List<MailboxRow>>(
        accountId,
        () => _syncMailboxes(accountId),
      );

  Future<Result<List<MailboxRow>>> _syncMailboxes(int accountId) async {
    final listed = await _connection.imap.listMailboxes();
    if (listed is Err<List<RemoteMailbox>>) return Err(listed.failure);
    // Gizli ayar klasörü (etiket/imza eşitlemesi) bir posta klasörü değildir:
    // yan menüde görünmez, iletileri eşitlenmez.
    final remote = (listed as Ok<List<RemoteMailbox>>).value
        .where((box) => !isSettingsMailbox(box.path, box.delimiter))
        .toList();

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
    await _db.transaction(() async {
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

      // Drift watchers now observe one reconciled snapshot, not intermediate
      // states between individual remote folder rows.
      if (seenPaths.isNotEmpty) {
        final local = await _db.mailboxesOf(accountId);
        for (final row in local) {
          if (seenPaths.contains(row.path)) continue;
          await _db.purgeMailboxMessages(row.id);
          // Keep a folder only when it still owns local-only drafts/outbox.
          if (!await _db.hasLocalOnlyMessages(row.id)) {
            await _db.deleteMailboxWithMessages(row.id);
          }
        }
      }
    });

    return Ok(await _db.mailboxesOf(accountId));
  }

  // -------------------------------------------------------------- iletiler

  /// Bir klasörü eşitler.
  Future<Result<SyncOutcome>> syncMailbox({
    required int accountId,
    required MailboxRow mailbox,
  }) {
    if (!mailbox.isSelectable) return Future.value(const Ok(SyncOutcome()));
    return _connection.exclusive<SyncOutcome>(
      accountId,
      () => _syncMailbox(accountId: accountId, mailbox: mailbox),
    );
  }

  Future<Result<SyncOutcome>> _syncMailbox({
    required int accountId,
    required MailboxRow mailbox,
  }) async {
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

    // `uidNext`, `highestModSeq` ve `totalCount` ("son tam uzlaşmadaki
    // sunucu durumu") burada YAZILMAZ: yalnızca silinenler ve bayraklar da
    // başarıyla uzlaştırıldığında en sonda yazılır (bkz. aşağısı). Erken
    // yazılsaydı geçici bir hata bir sonraki turun "değişiklik yok" sanıp
    // atlamasına ve kaçan değişikliğin kalıcı olarak kaybolmasına yol açardı.
    await _db.updateMailboxSync(
      mailbox.id,
      uidValidity: state.uidValidity,
      lastSyncAt: DateTime.now().toUtc(),
    );

    if (state.messageCount == 0) {
      // Sunucuda hiç ileti kalmadı (başka bir cihazdan Gelen Kutusu/Çöp
      // boşaltıldı). Yerelde kalan sunucu kaynaklı satırlar artık hayalettir:
      // silme adımı atlanırsa sonsuza dek görünürler.
      final vanished = await _syncDeletions(mailbox);
      if (vanished is Ok<int>) {
        await _db.updateMailboxSync(
          mailbox.id,
          uidNext: state.uidNext > 0 ? state.uidNext : null,
          highestModSeq: state.highestModSeq,
          totalCount: 0,
          hasMoreOnServer: false,
        );
      } else {
        await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      }
      return Ok(
        SyncOutcome(
          resynced: resynced,
          deletedCount: vanished.valueOrNull ?? 0,
        ),
      );
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
      final diverted = await _divertBlockedSenders(accountId, mailbox);
      newIds = [
        for (final id in newIds)
          if (!diverted.contains(id)) id,
      ];
      await _db.updateMailboxSync(
        mailbox.id,
        uidNext: state.uidNext,
        highestModSeq: state.highestModSeq,
        totalCount: state.messageCount,
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

    final fromUid = localHighest != null ? localHighest + 1 : mailbox.uidNext!;
    if (state.uidNext > fromUid) {
      // Taşıma/silme sunucuya henüz işlenmemiş iletiler (kullanıcı az önce
      // arşivledi/sildi) sunucuda hâlâ durur; yerelde en yüksek UID onlar
      // olduğu için aralık çekimi onları listeye geri getirirdi.
      final fetched = await _fetchRangeAndStore(
        accountId,
        mailbox,
        fromUid: fromUid,
        toUid: state.uidNext - 1,
        skipUids: await _lockedUids(accountId, mailbox.id),
      );
      if (fetched is Err<List<int>>) return Err(fetched.failure);
      newIds = (fetched as Ok<List<int>>).value;
    }

    // Engellenen göndericilerin iletileri (yeni gelenler ve önceki bir turdan kalanlar)
    // sunucuda İstenmeyen'e taşınır; bildirim üretmesinler diye yeni listeden de çıkar.
    final diverted = await _divertBlockedSenders(accountId, mailbox);
    if (diverted.isNotEmpty) {
      newIds = [
        for (final id in newIds)
          if (!diverted.contains(id)) id,
      ];
    }

    // --- 3. Silinenler ve bayrak değişiklikleri ---------------------------
    // Her ikisi de başarıyla uzlaşırsa `reconciled` kalır ve sunucu durumu
    // (uidNext / modseq / ileti sayısı) kaydedilir; biri başarısız olursa
    // kayıt ilerletilmez ve sonraki tur işi yeniden dener.
    var reconciled = true;

    // Silinen (EXPUNGE) ileti sunucudaki ileti sayısını düşürür, yeni ileti
    // `uidNext`'i artırır; ikisi de aynı kalmışsa ne yeni ne silinmiş ileti
    // vardır ve klasördeki TÜM UID'leri (büyük klasörde yüzlerce KB)
    // getiren `UID SEARCH ALL` boşuna çalıştırılmaz.
    var deleted = 0;
    final serverChanged =
        mailbox.uidNext != state.uidNext ||
        mailbox.totalCount != state.messageCount;
    if (serverChanged) {
      final result = await _syncDeletions(mailbox);
      if (result is Ok<int>) {
        deleted = result.value;
      } else {
        reconciled = false;
      }
    }

    var changed = 0;
    final flags = await _syncFlags(accountId, mailbox, state, caps);
    if (flags is Ok<int>) {
      changed = flags.value;
    } else {
      reconciled = false;
    }

    if (reconciled) {
      await _db.updateMailboxSync(
        mailbox.id,
        uidNext: state.uidNext,
        highestModSeq: state.highestModSeq,
        totalCount: state.messageCount,
      );
    }

    return Ok(
      SyncOutcome(
        newMessageIds: newIds,
        changedCount: changed,
        deletedCount: deleted,
        resynced: resynced,
      ),
    );
  }

  /// Engellenen göndericilerin Gelen Kutusu iletilerini SUNUCUDA İstenmeyen klasörüne taşır
  /// (yalnızca yerelde gizlemek yetmez: web ve diğer istemciler de aynı sonucu görmeli).
  ///
  /// Gelen Kutusu seçiliyken, işlem kilidi altında çalışır. Taşıma başarısız olursa
  /// (çevrimdışı, sunucu hatası) hiçbir şey değişmez ve sonraki tur yeniden dener.
  /// Bekleyen bir işlemin (arşivle/sil/taşı) kilitlediği iletilere dokunulmaz. Dönüş: yerelden
  /// kaldırılan ileti kimlikleri. İstenmeyen klasörü senkronize edildiğinde iletiler orada belirir.
  Future<Set<int>> _divertBlockedSenders(int accountId, MailboxRow mailbox) async {
    if (mailbox.specialUse != SpecialUse.inbox) return const {};
    final blocked = await _db.blockedEmails(accountId);
    if (blocked.isEmpty) return const {};
    final junk = await _db.mailboxBySpecialUse(accountId, SpecialUse.junk);
    if (junk == null || junk.id == mailbox.id) return const {};
    final rows = await _db.messagesFromSenders(
      mailboxId: mailbox.id,
      emails: blocked,
    );
    if (rows.isEmpty) return const {};
    final locked = await _lockedUids(accountId, mailbox.id);
    final movable = [
      for (final row in rows)
        if (row.uid != null && !locked.contains(row.uid)) row,
    ];
    if (movable.isEmpty) return const {};
    final moved = await _connection.imap.moveMessages(
      uids: [for (final row in movable) row.uid!],
      targetPath: junk.path,
      sourcePath: mailbox.path,
    );
    if (moved is Err<void>) return const {};
    final ids = [for (final row in movable) row.id];
    await _db.deleteMessages(ids);
    return ids.toSet();
  }

  /// Daha eski iletileri sayfa sayfa indirir.
  Future<Result<int>> loadOlder({
    required int accountId,
    required MailboxRow mailbox,
    int count = pageSize,
  }) => _connection.exclusive<int>(
    accountId,
    () => _loadOlder(accountId: accountId, mailbox: mailbox, count: count),
  );

  Future<Result<int>> _loadOlder({
    required int accountId,
    required MailboxRow mailbox,
    required int count,
  }) async {
    // Çağıranın elindeki satır bayat olabilir; UIDVALIDITY doğrulaması için
    // güncel değer veritabanından okunur.
    final current = await _db.mailboxById(mailbox.id) ?? mailbox;
    final selected = await _connection.selectVerified(current);
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
  ///
  /// Bu işlem `unawaited` çalışır ve saniyelerce sürebilir; kullanıcı bu sırada
  /// başka klasöre/hesaba geçebilir. Bu yüzden bağlantı her parçada YENİDEN
  /// doğrulanır: hesap değişmişse ya da klasörün UIDVALIDITY'si değişmişse hiçbir
  /// şey çekilmez — aksi hâlde bu klasörün UID'leri başka bir klasörde/hesapta
  /// çekilip yanlış iletinin gövdesi buradaki satıra yazılırdı.
  Future<void> prefetchBodies({
    required int accountId,
    required MailboxRow mailbox,
    int limit = bodyPrefetchCount,
  }) async {
    if (!_connection.isConnectedTo(accountId)) return;

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

    final current = await _db.mailboxById(mailbox.id) ?? mailbox;

    for (var start = 0; start < rows.length; start += _prefetchChunk) {
      final chunk = rows.sublist(
        start,
        min(start + _prefetchChunk, rows.length),
      );

      final fetched = await _connection
          .locked<List<(MessageRow, FetchedBody)>?>(() async {
            if (!_connection.isConnectedTo(accountId)) return null;
            final selected = await _connection.selectVerified(current);
            if (selected is Err<MailboxState>) return null;

            final bodies = <(MessageRow, FetchedBody)>[];
            for (final row in chunk) {
              final result = await _connection.imap.fetchBody(row.uid!);
              // Tek bir bozuk/silinmiş ileti önizleme akışını durdurmamalı.
              if (result is Ok<FetchedBody>) bodies.add((row, result.value));
            }
            return bodies;
          });
      if (fetched == null) return;

      // Veritabanı yazımı kilidin DIŞINDA: IMAP işlemleri beklemesin.
      for (final (row, body) in fetched) {
        await storeBody(row, body);
      }
    }
  }

  /// Gövdeyi ve eklerini veritabanına yazar, önizlemeyi günceller.
  ///
  /// Hepsi tek transaction'dadır: liste ve sayaç akışları her yazmada yeniden
  /// sorgulanmak yerine yalnızca bir kez tetiklenir ve yarım kalmış bir yazım
  /// (gövde var, `bodyFetchedAt` yok gibi) oluşamaz.
  Future<void> storeBody(MessageRow row, FetchedBody body) async {
    final plain =
        body.plainText ??
        (body.html != null ? await _htmlToPlain(body.html!) : null);
    final preview = TextExtraction.buildPreview(plain);

    // İmza/logo gibi HTML gövdesine `cid:` ile gömülü inline parçalar gerçek
    // ek sayılmaz (bkz. `_AttachmentStrip`teki `!a.isInline` süzgeci) — yoksa
    // yalnızca gömülü görseli olan iletiler de "Ekleri Var" filtresine ve
    // ataç ikonuna yanlışlıkla girer. Bayrak gövdenin gerçek içeriğiyle her
    // zaman eşitlenir, böylece envelope aşamasında önceden yanlış "true"
    // yazılmış iletiler de gövde çekildiğinde kendiliğinden düzelir.
    final hasRealAttachments = body.attachments.any((a) => !a.isInline);

    await _db.transaction(() async {
      // İleti bu arada silinmiş/taşınmış olabilir (kullanıcı eylemi, eşitleme):
      // olmayan bir satıra gövde yazmak yabancı anahtar hatası verirdi.
      final current = await _db.messageById(row.id);
      if (current == null) return;

      final patch = MessagesCompanion(
        preview: preview.isNotEmpty && preview != current.preview
            ? Value(preview)
            : const Value.absent(),
        hasAttachments:
            body.attachments.isNotEmpty &&
                hasRealAttachments != current.hasAttachments
            ? Value(hasRealAttachments)
            : const Value.absent(),
      );
      await _db.upsertBody(
        messageId: row.id,
        plainText: plain,
        html: body.html,
        messagePatch: patch,
      );

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
      }
    });
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
    Set<int> skipUids = const {},
  }) async {
    final fetched = await _connection.imap.fetchEnvelopeRange(
      fromUid: fromUid,
      toUid: toUid,
    );
    if (fetched is Err<List<FetchedEnvelope>>) return Err(fetched.failure);
    final envelopes = (fetched as Ok<List<FetchedEnvelope>>).value;
    return Ok(
      await _storeEnvelopes(
        accountId,
        mailbox,
        skipUids.isEmpty
            ? envelopes
            : envelopes.where((e) => !skipUids.contains(e.uid)).toList(),
      ),
    );
  }

  /// Yerelden iyimser olarak kaldırılmış iletileri sunucudan geri yükler.
  ///
  /// Taşıma/silme geri alındığında ya da sunucuda başarısız olduğunda
  /// kullanılır: UID'ler hâlâ [mailbox]'ta duruyorsa zarfları yeniden
  /// çekilir. Artımlı eşitleme (`localHighest + 1`) silinmiş satırı kendiliğinden
  /// geri getirmez. Sunucuda artık olmayan UID'ler sessizce atlanır.
  ///
  /// Klasörün UIDVALIDITY'si değişmişse UID'ler başka iletileri gösterir;
  /// bu durumda hiçbir şey geri yüklenmez ve hata döner.
  Future<Result<int>> restoreMessages({
    required int accountId,
    required MailboxRow mailbox,
    required List<int> uids,
  }) {
    if (uids.isEmpty) return Future.value(const Ok(0));
    return _connection.exclusive<int>(accountId, () async {
      final current = await _db.mailboxById(mailbox.id) ?? mailbox;
      final selected = await _connection.selectVerified(current);
      if (selected is Err<MailboxState>) return Err(selected.failure);

      final fetched = await _fetchAndStore(accountId, mailbox, uids);
      if (fetched is Err<List<int>>) return Err(fetched.failure);
      return Ok((fetched as Ok<List<int>>).value.length);
    });
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
    final labelNamesByKeyword = await _labelNamesByKeyword(accountId);

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
          // Sunucudaki `\Draft` bayrağı yalnızca Taslaklar klasöründe anlamlı:
          // başka istemciden gelen/iletilen bir iletide kalmış bayrak, alınan
          // iletiyi düzenlenebilir taslağa çevirmemeli (açınca gövde yerine
          // yazma ekranı çıkardı).
          isDraft: Value(
            envelope.isDraft && mailbox.specialUse == SpecialUse.drafts,
          ),
          isDeleted: Value(envelope.isDeleted),
          hasAttachments: Value(envelope.hasAttachments),
          sizeBytes: Value(envelope.sizeBytes),
          labelsJson: Value(
            jsonEncode(
              _namesForKeywords(envelope.keywords, labelNamesByKeyword),
            ),
          ),
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

  /// Hesabın etiketlerini IMAP anahtar kelimesi → görünen ad eşlemesine
  /// çevirir (bkz. `AccountRepository.createLabel`, `MailRepository.setLabel`
  /// — anahtar kelime `Labels.imapKeyword`'de saklanır).
  ///
  /// Sunucudan gelen FLAGS/keywords listesi her zaman ham IMAP anahtar
  /// kelimesidir (örn. `kaydet_kisisel`); bu eşleme uygulanmazsa
  /// `messages.labelsJson`'a doğrudan yazılır ve arayüzde "Kişisel" yerine
  /// ham anahtar kelime görünür, etikete göre filtreleme de (adla
  /// karşılaştırdığı için) hiçbir sonuç bulamaz.
  Future<Map<String, String>> _labelNamesByKeyword(int accountId) async {
    final labels = await _db.labelsOf(accountId);
    return {
      for (final label in labels)
        if (label.imapKeyword != null) label.imapKeyword!: label.name,
    };
  }

  /// Bilinen anahtar kelimeleri görünen ada çevirir; bu hesaba ait hiçbir
  /// etiketle eşleşmeyen anahtar kelimeler (ör. henüz yerelde oluşturulmamış
  /// ya da başka bir istemciden gelen) sessizce elenir — ham hâliyle
  /// gösterilmeleri kullanıcıya anlamsız gelir.
  static List<String> _namesForKeywords(
    List<String> keywords,
    Map<String, String> namesByKeyword,
  ) => keywords.map((k) => namesByKeyword[k]).whereType<String>().toList();

  /// Sunucuda artık olmayan iletileri yerelden siler.
  ///
  /// Sunucudaki UID listesi alınamazsa hata döner (sessizce "0 silindi"
  /// denmez): çağıran uzlaşmayı tamamlanmamış sayar ve sonraki turda yeniden
  /// dener.
  Future<Result<int>> _syncDeletions(MailboxRow mailbox) async {
    final all = await _connection.imap.searchAllUids();
    if (all is Err<List<int>>) return Err(all.failure);
    final serverUids = (all as Ok<List<int>>).value.toSet();

    final localUids = await _db.uidsOf(mailbox.id);
    final vanished = localUids
        .where((uid) => !serverUids.contains(uid))
        .toList();
    if (vanished.isEmpty) return const Ok(0);

    await _db.deleteMessagesByUid(mailbox.id, vanished);
    return Ok(vanished.length);
  }

  /// Bayrak değişikliklerini yerele yansıtır.
  ///
  /// Bekleyen yerel işlemi olan iletiler atlanır; aksi hâlde kullanıcının
  /// az önce yaptığı değişiklik sunucudan gelen eski durumla geri alınır
  /// ve arayüzde "geri zıplama" görülür.
  ///
  /// Sunucu bayrakları alınamazsa hata döner: çağıran `highestModSeq`'i
  /// İLERLETMEZ. Aksi hâlde CONDSTORE `CHANGEDSINCE` bir sonraki turda bu
  /// turdaki değişiklikleri hiç görmez ve başka cihazda okunan bir ileti
  /// burada sonsuza dek okunmamış kalırdı.
  Future<Result<int>> _syncFlags(
    int accountId,
    MailboxRow mailbox,
    MailboxState state,
    ServerCapabilities caps,
  ) async {
    final localUids = await _db.uidsOf(mailbox.id);
    if (localUids.isEmpty) return const Ok(0);

    final hasCondStoreBaseline =
        caps.supportsCondStore &&
        mailbox.highestModSeq != null &&
        state.highestModSeq != null;

    // CONDSTORE: modseq son uzlaşmadan beri hiç artmadıysa ne bir bayrak ne
    // bir ileti değişmiştir — sunucuya hiç sormaya gerek yok.
    if (hasCondStoreBaseline && state.highestModSeq == mailbox.highestModSeq) {
      return const Ok(0);
    }
    final useCondStore =
        hasCondStoreBaseline && state.highestModSeq! > mailbox.highestModSeq!;

    final window = useCondStore
        ? localUids
        : (localUids..sort()).reversed.take(flagWindow).toList();

    final fetched = await _connection.imap.fetchFlags(
      window,
      changedSinceModSeq: useCondStore ? mailbox.highestModSeq : null,
    );
    if (fetched is Err<List<RemoteFlagState>>) return Err(fetched.failure);
    final states = (fetched as Ok<List<RemoteFlagState>>).value;
    if (states.isEmpty) return const Ok(0);

    final locked = await _lockedUids(accountId, mailbox.id);
    final labelNamesByKeyword = await _labelNamesByKeyword(accountId);
    // Satır başına ayrı sorgu yerine tek toplu okuma.
    final rows = await _db.messagesByUids(mailbox.id, [
      for (final remote in states) remote.uid,
    ]);

    final updates = <(int, MessagesCompanion)>[];
    for (final remote in states) {
      if (locked.contains(remote.uid)) continue;
      final row = rows[remote.uid];
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
      final labelsJson = jsonEncode(
        _namesForKeywords(keywords, labelNamesByKeyword),
      );

      if (row.isSeen == isSeen &&
          row.isFlagged == isFlagged &&
          row.isAnswered == isAnswered &&
          row.isForwarded == isForwarded &&
          row.labelsJson == labelsJson) {
        continue;
      }

      updates.add((
        row.id,
        MessagesCompanion(
          isSeen: Value(isSeen),
          isFlagged: Value(isFlagged),
          isAnswered: Value(isAnswered),
          isForwarded: Value(isForwarded),
          labelsJson: Value(labelsJson),
        ),
      ));
    }
    if (updates.isEmpty) return const Ok(0);

    // Tek transaction: liste akışları yazma başına değil bir kez yenilenir.
    await _db.transaction(() async {
      for (final (id, patch) in updates) {
        await _db.updateMessage(id, patch);
      }
    });
    return Ok(updates.length);
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
