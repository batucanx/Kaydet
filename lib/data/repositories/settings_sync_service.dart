import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/models/quick_template.dart';
import '../../domain/use_cases/label_keywords.dart';
import '../../domain/use_cases/settings_document.dart';
import '../../domain/use_cases/settings_merge.dart';
import '../database/app_database.dart';
import '../services/quick_templates_store.dart';
import '../services/settings_sync_state_store.dart';
import 'mail_connection.dart';
import 'sender_filter_sync.dart';

/// Hesabın etiketlerini, imzalarını, hazır şablonlarını ve engellenen kullanıcılarını web istemcisiyle IMAP sunucusundaki tek
/// bir JSON belgesi üzerinden eşit tutar.
///
/// Biçim ve birleştirme kuralları `settings_document.dart` ve
/// `settings_merge.dart` içindedir (web projesindeki `packages/domain/src/
/// settings/` ile aynı davranır). Bu sınıf tesisatı yapar: gizli klasörü bul
/// ya da oluştur, en yeni belgeyi oku, yerelle ve son birleştirilen durumla üç
/// yönlü birleştir, değişeni yerele uygula, sunucudakinden farklıysa yeni sürüm
/// yaz ve sonucu bir sonraki birleştirmenin atası olarak sakla.
///
/// Hata olursa saklanan durum DEĞİŞMEZ: bir sonraki deneme aynı atadan başlar
/// ve yakınsar. Tüm IMAP işlemleri hesap başına tek mantıksal işlem olarak
/// ([MailConnection.exclusive]) çalışır; başka bir klasör seçimi araya giremez.
class SettingsSyncService {
  SettingsSyncService({
    required AppDatabase database,
    required MailConnection connection,
    required SettingsSyncStateStore state,
    QuickTemplatesStore? templates,
    this.onTemplatesChanged,
    SenderFilterSync? senderFilter,
    DateTime Function()? now,
    this.writer = 'mobile',
    this.seedsDefaults = false,
  }) : _db = database,
       _connection = connection,
       _state = state,
       _templates = templates,
       _senderFilter = senderFilter,
       _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MailConnection _connection;
  final SettingsSyncStateStore _state;
  final DateTime Function() _now;

  /// Sunucudaki filtreyi (Sieve) engellenenler listesiyle aynı tutar. `null` iken filtre hiç yönetilmez.
  final SenderFilterSync? _senderFilter;

  /// Hazır şablonların deposu (cihaza özgü, hesaba değil). `null` iken şablonlar eşitlemeye hiç
  /// katılmaz: olduğu gibi taşınır, yerelde bir şey değişmez.
  final QuickTemplatesStore? _templates;

  /// Eşitleme şablonları yerelde değiştirince çağrılır (arayüz listesini yenilemek için).
  final void Function()? onTemplatesChanged;

  /// Belgede `writer` olarak görünen istemci adı.
  final String writer;

  /// Yeni hesabın varsayılan etiketlerini ve imzasını bu servis oluşturur (bkz. [defaultLabelSeeds]).
  ///
  /// Hesap eklenirken yerelde oluşturulsaydı, hesabı silip yeniden ekleyen kullanıcının (ya da web'de
  /// varsayılanları silmiş bir kullanıcının) sunucudaki belgesi okunmadan varsayılanlar yerelde yeniden
  /// doğar ve "burada eklendi" sayılıp belgeye geri yazılırdı. Burada yalnızca ilk karşılaşmada ve
  /// sunucuda belge YOKKEN oluşturulur; belge varsa hesabın etiketleri belgenin dediğidir.
  final bool seedsDefaults;

  /// Yeni bir hesabın etiketleri: (ad, ton).
  static const List<(String, int)> defaultLabelSeeds = [
    ('İş', 10),
    ('Kişisel', 6),
    ('Tasarım', 12),
    ('Finans', 3),
  ];

  /// Yeni bir hesabın ilk imzasının gövdesi.
  static String defaultSignatureBody(String displayName) =>
      '\n\n--\n$displayName\nKaydet ile gönderildi';

  /// Çok sık ardışık turlar (her eşitlemede) sunucuyu boşuna yormasın. Web'de yapılan
  /// etiket/imza değişikliği telefona en geç bu sürenin ardındaki ilk yoklamada iner.
  static const Duration _minGap = Duration(seconds: 10);

  final Map<int, Future<Result<void>>> _running = {};
  final Map<int, Timer> _scheduled = {};
  final Map<int, DateTime> _lastRun = {};

  /// Ayar klasörü bu oturumda zaten abonelikten çıkarılan hesaplar (komut idempotenttir).
  final Set<int> _hidden = {};

  /// Ayar klasörü uygulama ayrıntısıdır: webmail klasör listesinde görünmesin diye abonelikten
  /// çıkarılır. Yalnızca görünüm içindir; hata eşitlemeyi durdurmaz, sonraki turda yeniden denenir.
  Future<void> _hideMailbox(int accountId, RemoteMailbox box) async {
    if (_hidden.contains(accountId)) return;
    final result = await _connection.imap.unsubscribeMailbox(
      box.encodedPath.isEmpty ? box.path : box.encodedPath,
    );
    if (result is Ok<void>) _hidden.add(accountId);
  }

  /// Ayar klasörünün son eşitlemedeki yolu ve durumu (UIDVALIDITY/UIDNEXT/ileti sayısı);
  /// [hasRemoteChange] yoklaması bununla karşılaştırır.
  final Map<int, ({String path, String signature})> _seen = {};

  static String _signature(MailboxState state) =>
      '${state.uidValidity}:${state.uidNext}:${state.messageCount}';

  /// Web (ya da başka bir istemci) ayar belgesini değiştirdi mi? Tek bir `STATUS`
  /// komutudur: seçili klasörü değiştirmez, belgeyi indirmez. Klasörün yolu ya da
  /// önceki durumu bilinmiyorsa (ilk tur, yazımdan sonra) `true` döner; böylece tam tur
  /// bir kez çalışıp durumu öğrenir. Hata halinde `false`: tam tur yoklamada denenir.
  Future<bool> hasRemoteChange(int accountId) async {
    final seen = _seen[accountId];
    if (seen == null) return true;
    final status = await _connection.exclusive<MailboxState>(
      accountId,
      () => _connection.imap.statusMailbox(seen.path),
    );
    if (status is! Ok<MailboxState>) return false;
    return _signature(status.value) != seen.signature;
  }

  /// Bir eşitleme turu çalıştırır; aynı hesap için süren bir tur varsa ona katılır.
  /// [force] `false` iken son turdan beri [_minGap] geçmediyse hiçbir şey yapmaz.
  Future<Result<void>> sync(int accountId, {bool force = false}) {
    final running = _running[accountId];
    if (running != null) return running;
    final last = _lastRun[accountId];
    if (!force && last != null && _now().difference(last) < _minGap) {
      return Future.value(okVoid);
    }
    final run = _syncNow(accountId).whenComplete(() {
      _running.remove(accountId);
      _lastRun[accountId] = _now();
    });
    _running[accountId] = run;
    return run;
  }

  /// Yerelde bir etiket/imza değişti: yakında eşitle (art arda değişiklikler tek yazımı paylaşır).
  void schedule(int accountId, {Duration delay = const Duration(seconds: 2)}) {
    _scheduled.remove(accountId)?.cancel();
    _scheduled[accountId] = Timer(delay, () {
      _scheduled.remove(accountId);
      unawaited(sync(accountId, force: true));
    });
  }

  /// Cihazdaki hazır şablonlar değişti: tüm hesapların ayar belgesini yakında eşitle.
  void scheduleAll() {
    unawaited(() async {
      for (final account in await _db.allAccounts()) {
        schedule(account.id);
      }
    }());
  }

  void dispose() {
    for (final timer in _scheduled.values) {
      timer.cancel();
    }
    _scheduled.clear();
  }

  // ------------------------------------------------------------------ tur

  Future<Result<void>> _syncNow(int accountId) =>
      _connection.exclusive<void>(accountId, () => _run(accountId));

  Future<Result<void>> _run(int accountId) async {
    final imap = _connection.imap;

    // 1. Belge nerede, ne diyor?
    final listed = await imap.listMailboxes();
    if (listed is Err<List<RemoteMailbox>>) return Err(listed.failure);
    final boxes = (listed as Ok<List<RemoteMailbox>>).value;
    RemoteMailbox? settingsBox;
    for (final box in boxes) {
      if (isSettingsMailbox(box.path, box.delimiter)) {
        settingsBox = box;
        break;
      }
    }

    var texts = <String>[];
    var previousUids = <int>[];
    if (settingsBox != null) {
      await _hideMailbox(accountId, settingsBox);
      final selected = await imap.selectMailbox(settingsBox.path);
      if (selected is Err<MailboxState>) return Err(selected.failure);
      _seen[accountId] = (
        path: settingsBox.encodedPath.isEmpty
            ? settingsBox.path
            : settingsBox.encodedPath,
        signature: _signature((selected as Ok<MailboxState>).value),
      );
      final uids = await imap.searchAllUids();
      if (uids is Err<List<int>>) return Err(uids.failure);
      previousUids = (uids as Ok<List<int>>).value;
      // En yeni birkaç ileti yeter (normalde tek ileti vardır).
      final recent = previousUids.length > _maxDocuments
          ? previousUids.sublist(previousUids.length - _maxDocuments)
          : previousUids;
      for (final uid in recent) {
        final body = await imap.fetchBody(uid);
        if (body is Err<FetchedBody>) return Err(body.failure);
        final text = (body as Ok<FetchedBody>).value.plainText;
        if (text != null) texts.add(text);
      }
    }
    final latest = pickLatestSettings(texts);
    if (latest is NewerSettings) return okVoid; // daha yeni biçim: dokunma

    final remoteFull = latest is FoundSettings ? latest.document.data : null;
    final remoteRev = latest is FoundSettings ? latest.document.rev : 0;
    final split = _splitRepresentable(remoteFull ?? SettingsData.empty);

    // 2. Üç yönlü birleştirme.
    final state = await _state.read(accountId);
    final firstContact = _parseBase(state.baseJson) == null;
    final templateStore = _templates;
    if (remoteFull != null &&
        firstContact &&
        templateStore != null &&
        templateStore.isPristine) {
      // Yeni kurulum: yerel şablonlar kullanıcının seçimi değil, dokunulmamış yerleşik varsayılanlardır.
      // Belge varsa şablonların doğrusu odur (web'de hepsi silinmişse boş kalmalı): birleştirmeye girmeden
      // yerel depo belgeyle değiştirilir; aksi hâlde varsayılanlar "burada eklendi" sayılıp geri dönerdi.
      await templateStore.replaceAll([
        for (final e in split.view.templates.entries) _templateOf(e.key, e.value),
      ]);
      onTemplatesChanged?.call();
    }
    var local = await _readLocal(accountId, split.view.templates);
    if (seedsDefaults &&
        remoteFull == null &&
        firstContact &&
        await _seedDefaults(accountId, local)) {
      local = await _readLocal(accountId, split.view.templates);
    }
    final result = mergeSettings(
      base: _parseBase(state.baseJson),
      local: local.data,
      remote: remoteFull == null ? null : split.view,
    );

    // 3. Karşı taraftaki değişiklikler buraya iner.
    if (result.localChanged) {
      await _applyLocal(accountId, result.merged, local);
      await _applyTemplates(result.merged.templates, local.templatesById);
    }

    // 4. Buradaki değişiklikler (ve birleştirme farkı) sunucuya gider.
    final full = SettingsData(
      labels: {...result.merged.labels, ...split.skipped.labels},
      signatures: {...result.merged.signatures, ...split.skipped.signatures},
      templates: {...result.merged.templates, ...split.skipped.templates},
      blockedSenders: {
        ...result.merged.blockedSenders,
        ...split.skipped.blockedSenders,
      },
    );
    final hasAny =
        full.labels.isNotEmpty ||
        full.signatures.isNotEmpty ||
        full.templates.isNotEmpty ||
        full.blockedSenders.isNotEmpty;
    final push = remoteFull == null
        ? hasAny
        : !settingsDataEqual(full, remoteFull);
    var rev = state.rev > remoteRev ? state.rev : remoteRev;
    if (push) {
      rev += 1;
      final written = await _write(
        accountId: accountId,
        boxes: boxes,
        existing: settingsBox,
        previousUids: previousUids,
        document: SettingsDocument(
          rev: rev,
          updatedAt: _now().toUtc().toIso8601String(),
          writer: writer,
          data: full,
        ),
      );
      if (written is Err<void>) return written;
      _seen.remove(
        accountId,
      ); // yeni sürüm yazıldı: durum bir sonraki turda yeniden öğrenilir
    }

    await _state.write(
      accountId,
      SettingsSyncState(baseJson: jsonEncode(result.merged.toJson()), rev: rev),
    );
    // Sunucudaki kural listeyi izler: liste karşı taraftan değiştiyse zorlanır, aksi hâlde sessiz bir
    // denetim (kimse engelli değilse ya da zaten uygulanmışsa atlanır).
    _senderFilter?.request(
      accountId,
      force: !settingsDeepEqual(
        result.merged.blockedSenders,
        local.data.blockedSenders,
      ),
    );
    return okVoid;
  }

  static const int _maxDocuments = 20;

  /// Tamamen yeni bir hesap (belge yok, daha önce eşitlenmemiş) varsayılan etiket ve imzayla başlar.
  /// Hesabın zaten etiketi/imzası varsa o alana dokunulmaz. Bir şey eklendiyse `true`.
  Future<bool> _seedDefaults(int accountId, _Local local) async {
    var seeded = false;
    if (local.labelsByKey.isEmpty) {
      for (final (name, tone) in defaultLabelSeeds) {
        await _db.insertLabel(
          LabelsCompanion.insert(
            accountId: accountId,
            name: name,
            toneIndex: Value(tone),
            imapKeyword: Value(labelImapKeyword(name)),
          ),
        );
      }
      seeded = true;
    }
    if (local.signaturesByKey.isEmpty) {
      final account = await _db.accountById(accountId);
      if (account != null) {
        await _db.insertSignature(
          SignaturesCompanion.insert(
            accountId: accountId,
            name: 'İmza 1',
            body: Value(defaultSignatureBody(account.displayName)),
            isDefault: const Value(true),
          ),
        );
        seeded = true;
      }
    }
    return seeded;
  }

  SettingsData? _parseBase(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return null;
      return SettingsData.fromJson(decoded);
    } on FormatException {
      return null; // bozuk ata "ilk karşılaşma"ya döner: sunucu kazanır, hiçbir şey silinmez
    }
  }

  /// Yeni sürümü ekler, SONRA eskileri siler (yeni sürüm güvendeyken).
  Future<Result<void>> _write({
    required int accountId,
    required List<RemoteMailbox> boxes,
    required RemoteMailbox? existing,
    required List<int> previousUids,
    required SettingsDocument document,
  }) async {
    final imap = _connection.imap;
    final account = await _db.accountById(accountId);
    if (account == null) return const Err(UnknownFailure(detail: 'hesap yok'));

    var path = existing?.path;
    if (path == null) {
      // Diğer kullanıcı klasörleri gibi Gelen Kutusu'nun altında oluşturulur.
      RemoteMailbox? inbox;
      for (final box in boxes) {
        if (box.specialUse == SpecialUse.inbox ||
            box.path.toUpperCase() == 'INBOX') {
          inbox = box;
          break;
        }
      }
      path = inbox == null
          ? settingsMailboxName
          : '${inbox.path}${inbox.delimiter}$settingsMailboxName';
      final created = await imap.createMailbox(path);
      if (created is Err<void>) {
        // Telefonla web aynı anda oluşturmuş olabilir: varsa devam et.
        final again = await imap.listMailboxes();
        final exists =
            again is Ok<List<RemoteMailbox>> &&
            again.value.any((b) => isSettingsMailbox(b.path, b.delimiter));
        if (!exists) return created;
      }
      await _hideMailbox(
        accountId,
        RemoteMailbox(
          path: path,
          name: settingsMailboxName,
          delimiter: '.',
          specialUse: SpecialUse.custom,
        ),
      );
    }

    final mime = buildSettingsMime(
      from: account.email,
      text: serializeSettingsDocument(document),
      date: _now(),
      messageId: '${_now().microsecondsSinceEpoch}.${document.rev}',
    );
    final appended = await imap.appendMessage(
      mimeSource: mime,
      targetPath: path,
      flags: const [r'\Seen'],
    );
    if (appended is Err<int?>) return Err(appended.failure);

    if (previousUids.isNotEmpty) {
      final selected = await imap.selectMailbox(path);
      if (selected is Err<MailboxState>) return Err(selected.failure);
      final removed = await imap.deletePermanently(previousUids);
      if (removed is Err<void>) return removed;
    }
    return okVoid;
  }

  // ------------------------------------------------------------ yerel veri

  Future<_Local> _readLocal(
    int accountId,
    SettingsCollection remoteTemplates,
  ) async {
    final labelRows = await _db.labelsOf(accountId);
    final labelsByKey = <String, LabelRow>{};
    final labelRecords = <String, SettingsRecord>{};
    for (final row in labelRows) {
      final key = row.imapKeyword ?? labelImapKeyword(row.name);
      labelsByKey[key] = row;
      labelRecords[key] = {'name': row.name, 'tone': row.toneIndex};
    }

    final sigRows = await _db.signaturesOf(accountId)
      ..sort((a, b) => a.id.compareTo(b.id));
    final sigsByKey = <String, SignatureRow>{};
    final sigRecords = <String, SettingsRecord>{};
    for (final row in sigRows) {
      var key = row.name;
      for (var n = 2; sigsByKey.containsKey(key); n++) {
        key = '${row.name}#$n';
      }
      sigsByKey[key] = row;
      sigRecords[key] = {
        'name': row.name,
        'body': row.body,
        'isDefault': row.isDefault,
        // Cihazdaki görsel başka cihaza taşınamaz: görsel alanları belgeye
        // yazılmaz, karşı taraftakiler de bu imzanın görselini ezmez.
        if (row.imageType != 'local') ...{
          'imageType': row.imageType,
          'remoteImageUrl': row.remoteImageUrl,
          'imageWidth': row.imageWidth,
          'imagePosition': row.imagePosition,
        },
      };
    }
    final blockedRows = await _db.blockedSendersOf(accountId);
    final blockedByEmail = {for (final row in blockedRows) row.email: row};
    final blockedRecords = <String, SettingsRecord>{
      for (final row in blockedRows) row.email: {'email': row.email, 'name': row.name},
    };
    final store = _templates;
    final templatesById = <String, QuickTemplate>{};
    final templateRecords = <String, SettingsRecord>{};
    if (store == null) {
      // Şablonlar bu örnekte eşitlenmiyor: uzaktakini aynen "yerel" say, hiçbir şey değişmesin.
      templateRecords.addAll(remoteTemplates);
    } else {
      for (final t in store.read()) {
        templatesById[t.id] = t;
        templateRecords[t.id] = {
          'title': t.title,
          'content': t.content,
          'isBuiltIn': t.isBuiltIn,
        };
      }
    }
    return _Local(
      data: SettingsData(
        labels: labelRecords,
        signatures: sigRecords,
        templates: templateRecords,
        blockedSenders: blockedRecords,
      ),
      labelsByKey: labelsByKey,
      signaturesByKey: sigsByKey,
      templatesById: templatesById,
      blockedByEmail: blockedByEmail,
    );
  }

  /// Belgede olup bu uygulamanın tutamayacağı kayıtlar (biçimi bozuk): yargılanmaz, olduğu gibi taşınır.
  ({SettingsData view, SettingsData skipped}) _splitRepresentable(
    SettingsData remote,
  ) {
    final labels = <String, SettingsRecord>{};
    final skippedLabels = <String, SettingsRecord>{};
    for (final entry in remote.labels.entries) {
      final name = entry.value['name'];
      final tone = entry.value['tone'];
      final ok =
          name is String &&
          name.trim().isNotEmpty &&
          tone is num &&
          tone == tone.toInt() &&
          tone >= 0;
      (ok ? labels : skippedLabels)[entry.key] = entry.value;
    }
    final sigs = <String, SettingsRecord>{};
    final skippedSigs = <String, SettingsRecord>{};
    for (final entry in remote.signatures.entries) {
      final r = entry.value;
      final ok =
          r['name'] is String &&
          (r['name']! as String).trim().isNotEmpty &&
          r['body'] is String &&
          r['isDefault'] is bool;
      (ok ? sigs : skippedSigs)[entry.key] = r;
    }
    final templates = <String, SettingsRecord>{};
    final skippedTemplates = <String, SettingsRecord>{};
    for (final entry in remote.templates.entries) {
      final r = entry.value;
      final ok = r['title'] is String &&
          (r['title']! as String).trim().isNotEmpty &&
          r['content'] is String &&
          r['isBuiltIn'] is bool;
      (ok ? templates : skippedTemplates)[entry.key] = r;
    }
    final blocked = <String, SettingsRecord>{};
    final skippedBlocked = <String, SettingsRecord>{};
    for (final entry in remote.blockedSenders.entries) {
      final r = entry.value;
      final email = r['email'];
      final name = r['name'];
      final ok =
          email is String &&
          email == entry.key &&
          email == email.toLowerCase() &&
          EmailAddress.isValidEmail(email) &&
          (name == null || name is String);
      (ok ? blocked : skippedBlocked)[entry.key] = r;
    }
    return (
      view: SettingsData(
        labels: labels,
        signatures: sigs,
        templates: templates,
        blockedSenders: blocked,
      ),
      skipped: SettingsData(
        labels: skippedLabels,
        signatures: skippedSigs,
        templates: skippedTemplates,
        blockedSenders: skippedBlocked,
      ),
    );
  }

  /// Birleşik şablon kümesini yerel depoya yazar: silinenler gider, değişenler güncellenir, yeniler başa eklenir.
  Future<void> _applyTemplates(
    SettingsCollection merged,
    Map<String, QuickTemplate> local,
  ) async {
    final store = _templates;
    if (store == null) return;
    final before = store.read();
    final kept = <QuickTemplate>[];
    for (final existing in before) {
      final record = merged[existing.id];
      if (record == null) continue; // karşı tarafta silindi
      kept.add(_templateOf(existing.id, record));
    }
    final added = [
      for (final entry in merged.entries)
        if (!local.containsKey(entry.key)) _templateOf(entry.key, entry.value),
    ];
    final result = [...added, ...kept];
    var same = before.length == result.length;
    for (var i = 0; same && i < before.length; i++) {
      same = before[i] == result[i];
    }
    if (same) return;
    await store.replaceAll(result);
    onTemplatesChanged?.call();
  }

  QuickTemplate _templateOf(String id, SettingsRecord r) => QuickTemplate(
    id: id,
    title: (r['title']! as String).trim(),
    content: r['content']! as String,
    isBuiltIn: r['isBuiltIn'] == true,
  );

  Future<void> _applyLocal(
    int accountId,
    SettingsData merged,
    _Local local,
  ) => _db.transaction(() async {
    // ---- etiketler
    final namesInUse = {for (final row in local.labelsByKey.values) row.name};
    for (final entry in merged.labels.entries) {
      final key = entry.key;
      final name = (entry.value['name']! as String).trim();
      final tone = (entry.value['tone']! as num).toInt();
      final existing = local.labelsByKey[key];
      if (existing == null) {
        // Başka bir anahtarla aynı adlı etiket varsa ona dokunma ((hesap, ad) benzersiz).
        if (namesInUse.contains(name)) continue;
        namesInUse.add(name);
        await _db.insertLabel(
          LabelsCompanion.insert(
            accountId: accountId,
            name: name,
            toneIndex: Value(tone),
            imapKeyword: Value(key),
          ),
        );
      } else if (existing.name != name || existing.toneIndex != tone) {
        final renameOk = existing.name == name || !namesInUse.contains(name);
        if (renameOk) {
          namesInUse.add(name);
          // İletiler etiketi adıyla tuttuğundan başka cihazdaki ad değişikliği
          // buradaki iletilere de yansır.
          if (existing.name != name) {
            await _db.rewriteLabelNames(accountId, existing.name, name);
          }
        }
        await _db.updateLabelRow(
          existing.id,
          LabelsCompanion(
            name: renameOk ? Value(name) : const Value.absent(),
            toneIndex: Value(tone),
            imapKeyword: Value(key),
          ),
        );
      }
    }
    for (final entry in local.labelsByKey.entries) {
      if (!merged.labels.containsKey(entry.key)) {
        await _db.deleteLabel(entry.value.id);
      }
    }

    // ---- imzalar
    final wanted = merged.signatures;
    for (final entry in local.signaturesByKey.entries) {
      if (!wanted.containsKey(entry.key)) {
        await _db.deleteSignature(entry.value.id);
      }
    }

    int? promote;
    final created = <String, int>{};
    // Önce silinenler, sonra vazgeçilen varsayılanlar, sonra güncellemeler, en sonda yükseltmeler:
    // "hesapta en fazla bir varsayılan" kısmi tekil indeksi her adımda korunur.
    for (final entry in wanted.entries) {
      final r = entry.value;
      final existing = local.signaturesByKey[entry.key];
      final isDefault = r['isDefault'] == true;
      final name = (r['name']! as String).trim();
      final body = r['body']! as String;
      final image = _imageFields(r, existing);
      if (existing == null) {
        final id = await _db.insertSignature(
          SignaturesCompanion.insert(
            accountId: accountId,
            name: name,
            body: Value(body),
            isDefault: const Value(false),
            imageType: Value(image.type),
            remoteImageUrl: Value(image.url),
            imageWidth: Value(image.width),
            imagePosition: Value(image.position),
          ),
        );
        created[entry.key] = id;
        if (isDefault) promote = id;
      } else {
        final changed =
            existing.name != name ||
            existing.body != body ||
            existing.imageType != image.type ||
            existing.remoteImageUrl != image.url ||
            existing.imageWidth != image.width ||
            existing.imagePosition != image.position;
        if (changed) {
          await _db.updateSignatureRow(
            existing.id,
            SignaturesCompanion(
              name: Value(name),
              body: Value(body),
              imageType: Value(image.type),
              remoteImageUrl: Value(image.url),
              imageWidth: Value(image.width),
              imagePosition: Value(image.position),
            ),
          );
        }
        if (existing.isDefault && !isDefault) {
          await _db.updateSignatureRow(
            existing.id,
            const SignaturesCompanion(isDefault: Value(false)),
          );
        } else if (!existing.isDefault && isDefault) {
          promote = existing.id;
        }
      }
    }
    if (promote != null) await _db.setDefaultSignature(accountId, promote);

    // ---- engellenen kullanıcılar. Engelleyen/kaldıran taraf iletileri sunucuda zaten taşıdı;
    // Gelen Kutusu taraması (bkz. `SyncEngine`) arta kalanı da toplar.
    for (final entry in local.blockedByEmail.entries) {
      if (!merged.blockedSenders.containsKey(entry.key)) {
        await _db.deleteBlockedSender(entry.value.id);
      }
    }
    for (final entry in merged.blockedSenders.entries) {
      final rawName = entry.value['name'];
      final name = rawName is String ? rawName : '';
      final existing = local.blockedByEmail[entry.key];
      if (existing == null) {
        await _db.insertBlockedSender(
          accountId: accountId,
          email: entry.key,
          name: name,
        );
      } else if (existing.name != name.trim()) {
        await _db.updateBlockedSenderName(existing.id, name);
      }
    }
  });

  /// Karşı taraftan gelen görsel alanlar; yoksa ya da bu imzanın görseli bu cihazdaysa yerelin kendi değerleri korunur.
  ({String type, String? url, int width, String position}) _imageFields(
    SettingsRecord remote,
    SignatureRow? existing,
  ) {
    final hasLocalImage = existing?.imageType == 'local';
    final type = remote['imageType'];
    if (hasLocalImage ||
        type is! String ||
        (type != 'none' && type != 'remote')) {
      return (
        type: existing?.imageType ?? 'none',
        url: existing?.remoteImageUrl,
        width: existing?.imageWidth ?? 200,
        position: existing?.imagePosition ?? 'bottom',
      );
    }
    final width = remote['imageWidth'];
    final position = remote['imagePosition'];
    final url = remote['remoteImageUrl'];
    return (
      type: type,
      url: url is String ? url : null,
      width: width is num && width > 0
          ? width.toInt()
          : (existing?.imageWidth ?? 200),
      position: position == 'top' || position == 'bottom'
          ? position! as String
          : (existing?.imagePosition ?? 'bottom'),
    );
  }
}

class _Local {
  const _Local({
    required this.data,
    required this.labelsByKey,
    required this.signaturesByKey,
    required this.templatesById,
    required this.blockedByEmail,
  });

  final SettingsData data;
  final Map<String, LabelRow> labelsByKey;
  final Map<String, SignatureRow> signaturesByKey;
  final Map<String, QuickTemplate> templatesById;
  final Map<String, BlockedSenderRow> blockedByEmail;
}
