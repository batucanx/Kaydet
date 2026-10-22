import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' show max, min;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import '../../core/result.dart';
import '../../core/turkish.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/models/search_filters.dart';
import '../../domain/use_cases/folder_mapping.dart';
import '../../domain/use_cases/settings_document.dart';
import '../../domain/use_cases/text_extraction.dart';
import '../../domain/use_cases/threading.dart';
import '../database/app_database.dart';
import '../services/imap_search_criteria.dart';
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

  /// Arka plan geri doldurmasında (bkz. `SyncController._startBackfill`)
  /// sayfa başına indirilen ileti sayısı.
  static const int backfillPageSize = 100;

  /// Artımlı eşitlemede tek FETCH'te istenen en çok UID aralığı.
  static const int incrementalChunk = 400;

  /// UID aralığı çok seyrekse (büyük boşluklar) en çok bu kadar istek atılır.
  static const int maxIncrementalChunks = 50;

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
  Future<Result<List<MailboxRow>>> syncMailboxes(int accountId) => _connection
      .exclusive<List<MailboxRow>>(accountId, () => _syncMailboxes(accountId));

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

  /// İletilerini indirmediğimiz klasörlerin (Arşiv, özel klasörler…)
  /// okunmamış sayısını SUNUCUDAN alıp `mailboxes.unreadCount`a yazar. Gelen
  /// Kutusu, Gönderilenler, Taslaklar, Çöp ve İstenmeyen yerel sayımla
  /// gösterilir; burada yoklanmaz.
  ///
  /// Sayı `STATUS (UNSEEN)` ile alınır; sıfırdan büyükse `\Deleted` işaretli
  /// iletiler çıkarılarak (`UID SEARCH UNSEEN UNDELETED`) doğrulanır — liste
  /// bu iletileri göstermez, rozet de saymamalı. [onlyMailboxIds] verilirse
  /// yalnızca o klasörler yoklanır.
  ///
  /// Her klasör KENDİ işlem kilidinde yoklanır: onlarca klasörü tek kilitte
  /// dolaşmak, bu sürede kullanıcının açtığı iletinin gövdesini beklettirirdi.
  /// Tek bir klasörün hatası turu bozmaz; bağlantı hatasında tur biter.
  Future<Result<int>> refreshUnreadCounts(
    int accountId, {
    Set<int>? onlyMailboxIds,
  }) async {
    final boxes = await _db.mailboxesOf(accountId);
    var updated = 0;
    for (final box in boxes) {
      if (onlyMailboxIds != null && !onlyMailboxIds.contains(box.id)) continue;
      // Abonelik bayrağına BAKILMAZ: `LIST` yanıtı `\Subscribed`'ı her
      // sunucuda döndürmez (ve yan menü abone olmayan klasörleri de gösterir);
      // abone görünmeyen klasörün rozeti sonsuza dek bayat kalırdı.
      if (!box.isSelectable) continue;
      if (_localCountedUses.contains(box.specialUse)) continue;
      final result = await _connection.exclusive<bool>(
        accountId,
        () => _refreshUnreadCount(accountId, box.id),
      );
      if (result is Err<bool>) {
        if (result.failure is ConnectionFailure) return Err(result.failure);
        continue;
      }
      if ((result as Ok<bool>).value) updated++;
    }
    return Ok(updated);
  }

  /// Aynı durumdaki (STATUS değerleri değişmemiş) klasörün doğrulanmış sayısı
  /// bu süre boyunca yeniden doğrulanmaz — doğrulama klasörü geçici seçer.
  static const _unseenCheckTtl = Duration(minutes: 10);
  final Map<int, _UnseenCheck> _unseenChecks = {};

  /// Tek klasörün sayısını yoklar; [MailConnection.exclusive] içinde çağrılır.
  /// Değer yazıldıysa `true`.
  Future<Result<bool>> _refreshUnreadCount(int accountId, int mailboxId) async {
    final box = await _db.mailboxById(mailboxId);
    if (box == null || !box.isSelectable) return const Ok(false);

    final status = await _connection.imap.statusMailbox(
      box.path,
      encodedPath: box.encodedPath,
      includeUnseen: true,
    );
    if (status is Err<MailboxState>) return Err(status.failure);
    final state = (status as Ok<MailboxState>).value;
    final reported = state.unseenCount;
    if (reported == null) return const Ok(false);

    var unseen = reported;
    if (reported > 0) {
      final cached = _unseenChecks[mailboxId];
      final fresh =
          cached != null &&
          cached.reported == reported &&
          cached.uidNext == state.uidNext &&
          cached.messageCount == state.messageCount &&
          DateTime.now().difference(cached.at) < _unseenCheckTtl;
      if (fresh) {
        unseen = cached.exact;
      } else {
        final exact = await _connection.imap.countUnseen(
          path: box.path,
          encodedPath: box.encodedPath,
        );
        if (exact is Ok<int>) {
          // `UNSEEN UNDELETED` hiçbir zaman `UNSEEN`den büyük olamaz.
          unseen = min(reported, exact.value);
          _unseenChecks[mailboxId] = _UnseenCheck(
            reported: reported,
            uidNext: state.uidNext,
            messageCount: state.messageCount,
            exact: unseen,
            at: DateTime.now(),
          );
        } else if ((exact as Err<int>).failure is ConnectionFailure) {
          return Err(exact.failure);
        }
        // Başka bir hata: doğrulanamadı, STATUS değeri kullanılır.
      }
    } else {
      _unseenChecks.remove(mailboxId);
    }

    // Bekleyen bir okundu/okunmadı/taşıma işlemi varken sunucudan okunan sayı
    // henüz o işlemi içermez; yazılırsa kullanıcının az önceki eylemi rozette
    // geri alınırdı. İşlem tamamlanınca kuyruk bu klasörü yeniden yoklar.
    if ((await _lockedUids(accountId, mailboxId)).isNotEmpty) {
      return const Ok(false);
    }

    final current = await _db.mailboxById(mailboxId);
    if (current == null) return const Ok(false);
    if (unseen != current.unreadCount) {
      await _db.setMailboxUnreadCount(mailboxId, unseen);
    }
    return const Ok(true);
  }

  static const _localCountedUses = {
    SpecialUse.inbox,
    SpecialUse.sent,
    SpecialUse.drafts,
    SpecialUse.trash,
    SpecialUse.junk,
  };

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
      encodedPath: mailbox.encodedPath,
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
          uidNext: state.uidNext > 0 ? state.uidNext : 1,
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
    final localCount = await _db.countMessages(mailbox.id);
    if (kDebugMode) {
      print(
        '[SYNC_ENGINE] Mailbox "${mailbox.path}" (id: ${mailbox.id}, encoded: "${mailbox.encodedPath}"): '
        'remoteExists=${state.messageCount}, uidValidity=${state.uidValidity}, '
        'uidNext=${state.uidNext}, localHighest=$localHighest, localDbCount=$localCount',
      );
    }
    List<int> newIds = const [];

    final neverSynced = mailbox.uidNext == null;
    final needsInitialFetch =
        resynced ||
        neverSynced ||
        (localHighest == null && state.messageCount > 0);
    if (needsInitialFetch) {
      // İlk indirme veya yerel DB'de henüz mesaj bulunmayan klasör: en yeni N ileti.
      // Sequence numaraları (1..messageCount) kullanılarak doğrudan son N ileti çekilir.
      if (state.messageCount > 0) {
        final fromSeq = (state.messageCount - initialFetchCount + 1).clamp(
          1,
          state.messageCount,
        );
        final toSeq = state.messageCount;
        if (kDebugMode) {
          print(
            '[SYNC_ENGINE] Initial fetch for "${mailbox.path}": seq $fromSeq..$toSeq',
          );
        }
        final fetched = await _fetchSequenceAndStore(
          accountId,
          mailbox,
          fromSeq: fromSeq,
          toSeq: toSeq,
        );
        if (fetched is Err<List<int>>) return Err(fetched.failure);
        newIds = (fetched as Ok<List<int>>).value;
        if (kDebugMode) {
          print(
            '[SYNC_ENGINE] Fetched ${newIds.length} envelopes for "${mailbox.path}": '
            'UIDs=${newIds.take(10).toList()}${newIds.length > 10 ? '...' : ''}',
          );
        }
        final diverted = await _divertBlockedSenders(accountId, mailbox);
        newIds = [
          for (final id in newIds)
            if (!diverted.contains(id)) id,
        ];
        // `uidNext` "ilk indirme tamamlandı" işaretidir (arayüz iskeleti buna
        // bakar, bkz. `mailListItemsProvider`): sunucu UIDNEXT bildirmese ya da
        // gelenlerin hepsi saptırılmış olsa bile null KALMAMALI.
        final nextUid = state.uidNext > 0
            ? state.uidNext
            : (newIds.isNotEmpty
                  ? (newIds.reduce((a, b) => a > b ? a : b) + 1)
                  : 1);
        await _db.updateMailboxSync(
          mailbox.id,
          uidNext: nextUid,
          highestModSeq: state.highestModSeq,
          totalCount: state.messageCount,
          hasMoreOnServer: fromSeq > 1,
        );
      } else {
        await _db.updateMailboxSync(
          mailbox.id,
          uidNext: state.uidNext > 0 ? state.uidNext : 1,
          highestModSeq: state.highestModSeq,
          totalCount: 0,
          hasMoreOnServer: false,
        );
      }
      return Ok(
        SyncOutcome(
          newMessageIds: newIds,
          resynced: resynced,
          initialDownload: neverSynced,
        ),
      );
    }

    // `localHighest + 1` tek başına güvenilir DEĞİL: bildirimden açılan tek bir
    // ileti (bkz. `fetchMessageByUid`) ya da APPEND edilen bir kopya, son
    // uzlaşmadan SONRAKİ bir UID'yi yerele yazar ve `localHighest`'i öne atar —
    // aradaki iletiler bir daha hiç çekilmezdi. Son uzlaşmada kaydedilen
    // `uidNext` bunun üst sınırıdır; küçük olan alınır (silinen son iletiler
    // yüzünden `localHighest + 1 < uidNext` ise davranış değişmez).
    final fromUid = localHighest != null
        ? min(localHighest + 1, mailbox.uidNext ?? localHighest + 1)
        : (mailbox.uidNext ?? 1);
    if (state.uidNext > fromUid) {
      if (kDebugMode) {
        print(
          '[SYNC_ENGINE] Incremental UID fetch for "${mailbox.path}": $fromUid..${state.uidNext - 1}',
        );
      }
      // Uzun süre çevrimdışı kalan / çok mail alan kullanıcıda tek bir dev
      // FETCH zaman aşımına düşer ve her turda aynı yerde tıkanırdı. Aralık
      // parçalara bölünür; her parça yazıldıkça `localHighest` ilerler, hata
      // olursa sonraki tur kaldığı yerden devam eder.
      final skip = await _lockedUids(accountId, mailbox.id);
      final lastUid = state.uidNext - 1;
      final span = lastUid - fromUid + 1;
      final chunk = max(incrementalChunk, (span / maxIncrementalChunks).ceil());
      final collected = <int>[];
      for (var start = fromUid; start <= lastUid; start += chunk) {
        final fetched = await _fetchRangeAndStore(
          accountId,
          mailbox,
          fromUid: start,
          toUid: min(start + chunk - 1, lastUid),
          skipUids: skip,
        );
        if (fetched is Err<List<int>>) return Err(fetched.failure);
        collected.addAll((fetched as Ok<List<int>>).value);
      }
      newIds = collected;
      if (kDebugMode) {
        print(
          '[SYNC_ENGINE] Fetched ${newIds.length} new envelopes for "${mailbox.path}"',
        );
      }
    } else if (state.uidNext <= 0 && state.messageCount > mailbox.totalCount) {
      // Sunucu UIDNEXT bildirmiyor (state.uidNext == 0): yeni iletileri sıra numarası artışıyla çek.
      final fromSeq = (mailbox.totalCount + 1).clamp(1, state.messageCount);
      final toSeq = state.messageCount;
      if (toSeq >= fromSeq) {
        if (kDebugMode) {
          print(
            '[SYNC_ENGINE] Sequence fetch for server without UIDNEXT: seq $fromSeq..$toSeq',
          );
        }
        final fetched = await _fetchSequenceAndStore(
          accountId,
          mailbox,
          fromSeq: fromSeq,
          toSeq: toSeq,
        );
        if (fetched is Err<List<int>>) return Err(fetched.failure);
        newIds = (fetched as Ok<List<int>>).value;
        if (kDebugMode) {
          print(
            '[SYNC_ENGINE] Fetched ${newIds.length} envelopes for "${mailbox.path}"',
          );
        }
      }
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
    //
    // Yalnızca yeni ileti gelmişse tarama da atlanır: her UID tek bir ileti
    // alır, UIDNEXT n arttıysa ve ileti sayısı da tam n arttıysa hiçbir ileti
    // silinmemiştir (bir silme sayıyı mutlaka düşürürdü). Sayı tutmuyorsa
    // (silme + yeni ileti aynı turda, UIDNEXT atlayan sunucu) tarama yapılır.
    var deleted = 0;
    final previousNext = mailbox.uidNext;
    final onlyArrivals =
        !resynced &&
        previousNext != null &&
        previousNext > 0 &&
        state.uidNext >= previousNext &&
        state.messageCount ==
            mailbox.totalCount + (state.uidNext - previousNext);
    final serverChanged =
        !onlyArrivals &&
        (mailbox.uidNext != state.uidNext ||
            mailbox.totalCount != state.messageCount);
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
  Future<Set<int>> _divertBlockedSenders(
    int accountId,
    MailboxRow mailbox,
  ) async {
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
      sourceEncodedPath: mailbox.encodedPath,
      targetEncodedPath: junk.encodedPath,
    );
    if (moved is Err<void>) return const {};
    final ids = [for (final row in movable) row.id];
    await _db.deleteMessages(ids);
    return ids.toSet();
  }

  /// Tek bir iletiyi UID'sine göre getirip yerele yazar (bildirim hedefi).
  ///
  /// Klasörün tamamını eşitlemez: tek `SELECT` + tek `UID FETCH` (+ gövde).
  /// Dönüş, yerel satırın kimliğidir; ileti sunucuda artık yoksa ya da klasörün
  /// UIDVALIDITY'si [expectedUidValidity]/yerel kayıttan farklıysa (UID artık
  /// başka bir iletiyi gösterir) `Ok(null)`.
  ///
  /// Klasörün eşitleme durumuna (`uidNext`, `highestModSeq`, …) DOKUNMAZ; tam
  /// eşitleme bunu kendi hesabıyla ve eksik iletileri tamamlayarak sürdürür
  /// (bkz. `_syncMailbox`'taki `fromUid`).
  Future<Result<int?>> fetchMessageByUid({
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? expectedUidValidity,
    bool withBody = true,
  }) => _connection.exclusive<int?>(accountId, () async {
    final current = await _db.mailboxById(mailbox.id) ?? mailbox;
    final selected = await _connection.imap.selectMailbox(
      current.path,
      encodedPath: current.encodedPath,
    );
    if (selected is Err<MailboxState>) return Err(selected.failure);
    final state = (selected as Ok<MailboxState>).value;

    final known = expectedUidValidity ?? current.uidValidity;
    if (known != null && state.uidValidity != 0 && known != state.uidValidity) {
      return const Ok(null);
    }

    final fetched = await _fetchAndStore(accountId, current, [uid]);
    if (fetched is Err<List<int>>) return Err(fetched.failure);
    final row = await _db.messageByUid(current.id, uid);
    if (row == null) return const Ok(null);

    if (withBody && row.bodyFetchedAt == null) {
      // Gövde bu bağlantı hâlâ ilgili klasör seçiliyken hemen alınır: ileti
      // ekranı içeriğiyle açılır, ana bağlantının işlem sırasını beklemez.
      // Başarısızlık iletiyi açmayı engellemez; ekran gövdeyi kendisi ister.
      final body = await _connection.imap.fetchBody(uid);
      if (body is Ok<FetchedBody>) await storeBody(row, body.value);
    }
    return Ok(row.id);
  });

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

    final lowestList = await _db.lowestUids(mailbox.id, limit: 1);
    if (lowestList.isEmpty) {
      final selectedState = (selected as Ok<MailboxState>).value;
      if (selectedState.messageCount > 0) {
        final fromSeq = (selectedState.messageCount - count + 1).clamp(
          1,
          selectedState.messageCount,
        );
        final toSeq = selectedState.messageCount;
        final fetched = await _fetchSequenceAndStore(
          accountId,
          mailbox,
          fromSeq: fromSeq,
          toSeq: toSeq,
        );
        if (fetched is Err<List<int>>) return Err(fetched.failure);
        final newIds = (fetched as Ok<List<int>>).value;
        await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: fromSeq > 1);
        return Ok(newIds.length);
      }
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      return const Ok(0);
    }
    final lowestUid = lowestList.first;
    if (lowestUid <= 1) {
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
      return const Ok(0);
    }

    // UID penceresiyle sayfalama: yereldeki en küçük UID'nin altındaki aralık
    // doğrudan `UID FETCH` ile çekilir. Sıra numarası aramasına (SEARCH) bağlı
    // DEĞİL: o arama başarısız/boş dönünce eski kod `hasMoreOnServer`'ı kalıcı
    // olarak kapatıyor ve eski iletiler bir daha hiç gelmiyordu. Bayrak yalnızca
    // UID 1'e gerçekten inildiğinde kapanır; hata durumunda dokunulmaz, bir
    // sonraki denemede kaldığı yerden devam edilir. UID'ler seyrek olabilir
    // (silinen iletiler): pencere boş dönerse genişletilerek aşağı inilir.
    var toUid = lowestUid - 1;
    var window = count;
    var fromUid = toUid;
    for (var attempt = 0; attempt < 60 && toUid >= 1; attempt++) {
      fromUid = max(1, toUid - window + 1);
      final fetched = await _fetchRangeAndStore(
        accountId,
        mailbox,
        fromUid: fromUid,
        toUid: toUid,
      );
      if (fetched is Err<List<int>>) return Err(fetched.failure);
      final stored = (fetched as Ok<List<int>>).value.length;
      if (stored > 0 || fromUid <= 1) {
        await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: fromUid > 1);
        return Ok(stored);
      }
      toUid = fromUid - 1;
      window = min(window * 2, 50000);
    }
    if (toUid < 1) {
      await _db.updateMailboxSync(mailbox.id, hasMoreOnServer: false);
    }
    return const Ok(0);
  }

  // ------------------------------------------------------- sunucu araması

  /// Sunucu aramasında bir klasörden en çok indirilecek ileti (en yeniler).
  static const int remoteSearchPerFolder = 40;

  /// Bir hesapta aranacak en çok klasör sayısı (yüzlerce etiketli bir
  /// hesapta klasör klasör gezilmez).
  static const int remoteSearchMaxFolders = 25;

  /// Aramadaki sözcükler: harf/rakam ve `@ . _ -` korunur (adres aranabilsin),
  /// büyük/küçük harf farkı olmadan tekrarlar atılır, en çok 5 sözcük.
  static List<String> remoteSearchWords(String query) {
    final words = query
        .split(RegExp(r'[^\p{L}\p{N}@._-]+', unicode: true))
        .map((w) => w.replaceAll(RegExp(r'^[-._]+|[-._]+$'), ''))
        .where((w) => w.isNotEmpty);
    final seen = <String>{};
    return [
      for (final word in words)
        if (seen.add(trLower(word))) word,
    ].take(5).toList();
  }

  /// Yerel kopyada OLMAYAN iletileri sunucuda arar ve bulduklarını "arama
  /// sonucu" olarak yerele yazar (bkz. [Messages.isSearchHit]); yerel arama
  /// akışı (bkz. `mailSearchResultsProvider`) tabloyu izlediği için sonuçlar
  /// listeye kendiliğinden eklenir.
  ///
  /// Yerel kopya her klasörün yalnızca en yeni iletilerini tutar; çok iletisi
  /// olan bir kullanıcının eski iletileri ancak bu yolla bulunur (Gmail,
  /// Outlook ve web istemcisindeki gibi). Metin, gönderen, alıcı ve tarih
  /// filtreleri sunucuda uygulanır; "Ekli" indirilen zarfın ek bilgisine
  /// bakar. Metin yoksa ve gönderen/alıcı/tarih da yoksa (yalnızca klasör ya
  /// da "Ekli") sunucuya gidilmez: tüm klasörü listelemek aramanın işi değil.
  ///
  /// [accountIds] aranacak hesaplar; her klasörden en yeni
  /// [remoteSearchPerFolder] yeni ileti indirilir. [isCancelled] `true`
  /// dönerse (kullanıcı başka bir şey aradı) klasörler arasında durulur.
  /// Dönüş: yazılan ileti sayısı; HİÇBİR klasör aranamadıysa (bağlantı yok)
  /// ilk hata.
  Future<Result<int>> searchRemote({
    required List<int> accountIds,
    required String query,
    required SearchFilters filters,
    bool Function()? isCancelled,
  }) async {
    final words = remoteSearchWords(query);
    final range = filters.dateRange;
    if (filters.hasDate && range == null) return const Ok(0); // ters pencere
    final criteria = ImapSearchCriteria.build(
      words: words,
      from: filters.sender,
      recipient: filters.recipient,
      since: filters.dateFrom,
      before: filters.dateTo == null
          ? null
          : DateTime(
              filters.dateTo!.year,
              filters.dateTo!.month,
              filters.dateTo!.day + 1,
            ),
    );
    if (criteria == null) return const Ok(0);

    var stored = 0;
    var searched = 0;
    AppFailure? firstFailure;
    for (final accountId in accountIds) {
      final targets = await _remoteSearchTargets(accountId, filters);
      var storedHere = 0;
      for (final mailbox in targets) {
        if (isCancelled?.call() ?? false) return Ok(stored);
        final result = await _connection.exclusive<int>(
          accountId,
          () => _searchRemoteMailbox(
            accountId: accountId,
            mailbox: mailbox,
            criteria: criteria,
            matchedText: words.join(' '),
            attachmentsOnly: filters.withAttachmentsOnly,
          ),
        );
        switch (result) {
          case Ok<int>(:final value):
            searched++;
            storedHere += value;
          case Err<int>(:final failure):
            firstFailure ??= failure;
        }
      }
      stored += storedHere;
      if (storedHere > 0) await _db.pruneSearchHits(accountId);
    }
    if (searched == 0 && firstFailure != null) return Err(firstFailure);
    return Ok(stored);
  }

  /// Aranacak klasörler, en yararlı olandan başlayarak (Gelen Kutusu,
  /// Gönderilenler, … Çöp Kutusu en sonda).
  Future<List<MailboxRow>> _remoteSearchTargets(
    int accountId,
    SearchFilters filters,
  ) async {
    const order = {
      SpecialUse.inbox: 0,
      SpecialUse.sent: 1,
      SpecialUse.archive: 2,
      SpecialUse.custom: 3,
      SpecialUse.drafts: 4,
      SpecialUse.junk: 5,
      SpecialUse.trash: 6,
    };
    final folder = filters.folder;
    final boxes =
        (await _db.selectableMailboxes(accountId: accountId)).where((box) {
          if (folder == null) {
            return filters.includeDeleted || box.specialUse != SpecialUse.trash;
          }
          return box.specialUse == folder.use &&
              (folder.customName == null || box.name == folder.customName);
        }).toList()..sort(
          (a, b) =>
              (order[a.specialUse] ?? 3).compareTo(order[b.specialUse] ?? 3),
        );
    return boxes.take(remoteSearchMaxFolders).toList();
  }

  /// Tek klasörde sunucu araması (işlem kilidi altında çağrılır).
  Future<Result<int>> _searchRemoteMailbox({
    required int accountId,
    required MailboxRow mailbox,
    required String criteria,
    required String matchedText,
    required bool attachmentsOnly,
  }) async {
    final current = await _db.mailboxById(mailbox.id) ?? mailbox;
    final selected = await _connection.selectVerified(current);
    if (selected is Err<MailboxState>) return Err(selected.failure);

    final found = await _connection.imap.searchUids(criteria);
    if (found is Err<List<int>>) return Err(found.failure);
    final uids = (found as Ok<List<int>>).value;
    if (uids.isEmpty) return const Ok(0);

    final unknown = await _db.unknownUids(current.id, uids)
      ..sort((a, b) => b.compareTo(a)); // en yeni önce
    if (unknown.isEmpty) return const Ok(0);

    final fetched = await _connection.imap.fetchEnvelopes(
      unknown.take(remoteSearchPerFolder).toList(),
    );
    if (fetched is Err<List<FetchedEnvelope>>) return Err(fetched.failure);
    final envelopes = [
      for (final e in (fetched as Ok<List<FetchedEnvelope>>).value)
        if (!e.isDeleted && (!attachmentsOnly || e.hasAttachments)) e,
    ]..sort((a, b) => a.date.compareTo(b.date));
    if (envelopes.isEmpty) return const Ok(0);

    final companions = await _companionsFor(accountId, current, envelopes);
    return Ok(await _db.upsertSearchHits(companions, matchedText: matchedText));
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

  Future<Result<List<int>>> _fetchSequenceAndStore(
    int accountId,
    MailboxRow mailbox, {
    required int fromSeq,
    required int toSeq,
  }) async {
    if (toSeq < fromSeq || fromSeq < 1) return const Ok(<int>[]);
    final fetched = await _connection.imap.fetchEnvelopeSequenceRange(
      fromSeq: fromSeq,
      toSeq: toSeq,
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
    final companions = await _companionsFor(accountId, mailbox, sorted);

    final inserted = await _db.upsertServerMessages(companions);

    // Yalnızca Gelen Kutusu: Gereksiz (spam) göndericilerini veya kendi
    // adresimizi (Gönderilenler'in "from"ı) kişi olarak eklemek istemeyiz.
    if (mailbox.specialUse == SpecialUse.inbox) {
      await _captureContactsFromInbox(accountId, sorted);
    }

    return inserted;
  }

  /// Zarfları (eski → yeni sıralı) yerel satırlara çevirir.
  Future<List<MessagesCompanion>> _companionsFor(
    int accountId,
    MailboxRow mailbox,
    List<FetchedEnvelope> sorted,
  ) async {
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
          // Sunucudaki Taslaklar klasöründeki tüm iletiler taslaktır.
          // Başka klasörlerdeki iletiler ise yanlışlıkla `\Draft` bayrağı taşısalar bile
          // taslak sayılmaz.
          isDraft: Value(mailbox.specialUse == SpecialUse.drafts),
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

    return companions;
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
    // 1. Bu partideki tüm referansları ve konuları topla.
    final referenced = <String>{};
    final subjectKeys = <String>{};
    for (final envelope in envelopes) {
      referenced.addAll(Threading.parseReferences(envelope.references));
      final inReplyTo = Threading.normalizeId(envelope.inReplyTo);
      if (inReplyTo != null) referenced.add(inReplyTo);
      final sKey = Threading.subjectKey(envelope.subject);
      if (sKey != null) subjectKeys.add(sKey);
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

    // 2b. Veritabanında aynı normalleştirilmiş konuya sahip konuşmaları bul.
    final knownBySubj = <String, String>{};
    if (subjectKeys.isNotEmpty) {
      final cleanSubjs = subjectKeys
          .map((s) => s.replaceFirst('subj:', ''))
          .toList();
      final subjRows =
          await (_db.select(_db.messages)..where(
                (m) =>
                    m.accountId.equals(accountId) &
                    m.subjectNormalized.isIn(cleanSubjs) &
                    m.threadId.isBiggerThanValue(''),
              ))
              .get();
      for (final row in subjRows) {
        final key = 'subj:${row.subjectNormalized}';
        if (!knownBySubj.containsKey(key)) {
          knownBySubj[key] = row.threadId;
        }
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
        knownBySubject: knownBySubj,
      );
      result[envelope.uid] = threadId;
      final own = Threading.normalizeId(envelope.messageId);
      if (own != null) known[own] = threadId;
      final sKey = Threading.subjectKey(envelope.subject);
      if (sKey != null) knownBySubj.putIfAbsent(sKey, () => threadId);
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
    final localUids = await _db.uidsOf(mailbox.id);
    if (localUids.isEmpty) return const Ok(0);

    // 100.000 iletili kutuda tüm sunucu UID'lerini indirmek yerine (UID SEARCH ALL),
    // yalnızca yerelde kayıtlı olan UID'lerin sunucuda hâlâ var olup olmadığı sorgulanır.
    final serverResult = await _connection.imap.searchUidsInSet(localUids);
    if (serverResult is Err<List<int>>) return Err(serverResult.failure);
    final serverUids = (serverResult as Ok<List<int>>).value.toSet();

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
      // Başka bir istemci iletiyi sonradan `\Deleted` işaretlediyse (ya da
      // işareti kaldırdıysa) liste ve rozetler sunucudaki gerçeği izlemeli.
      final isDeleted = remote.flags.contains(r'\Deleted');
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
          row.isDeleted == isDeleted &&
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
          isDeleted: Value(isDeleted),
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

/// Bir klasörün doğrulanmış okunmamış sayısı (bkz. `_refreshUnreadCount`).
class _UnseenCheck {
  const _UnseenCheck({
    required this.reported,
    required this.uidNext,
    required this.messageCount,
    required this.exact,
    required this.at,
  });

  /// Doğrulama anındaki `STATUS (UNSEEN)` değeri ve klasör durumu.
  final int reported;
  final int uidNext;
  final int messageCount;

  /// `\Deleted` işaretliler çıkarıldıktan sonraki sayı.
  final int exact;
  final DateTime at;
}
