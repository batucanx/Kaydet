import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/label_keywords.dart';
import '../../domain/use_cases/settings_document.dart';
import '../../domain/use_cases/settings_merge.dart';
import '../database/app_database.dart';
import '../services/settings_sync_state_store.dart';
import 'mail_connection.dart';

/// Hesabın etiketlerini ve imzalarını web istemcisiyle IMAP sunucusundaki tek
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
    DateTime Function()? now,
    this.writer = 'mobile',
  }) : _db = database,
       _connection = connection,
       _state = state,
       _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MailConnection _connection;
  final SettingsSyncStateStore _state;
  final DateTime Function() _now;

  /// Belgede `writer` olarak görünen istemci adı.
  final String writer;

  /// Çok sık ardışık turlar (her eşitlemede) sunucuyu boşuna yormasın.
  static const Duration _minGap = Duration(seconds: 45);

  final Map<int, Future<Result<void>>> _running = {};
  final Map<int, Timer> _scheduled = {};
  final Map<int, DateTime> _lastRun = {};

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
  void schedule(
    int accountId, {
    Duration delay = const Duration(seconds: 2),
  }) {
    _scheduled.remove(accountId)?.cancel();
    _scheduled[accountId] = Timer(delay, () {
      _scheduled.remove(accountId);
      unawaited(sync(accountId, force: true));
    });
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
      final selected = await imap.selectMailbox(settingsBox.path);
      if (selected is Err<MailboxState>) return Err(selected.failure);
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
    final local = await _readLocal(accountId);
    final state = await _state.read(accountId);
    final result = mergeSettings(
      base: _parseBase(state.baseJson),
      local: local.data,
      remote: remoteFull == null ? null : split.view,
    );

    // 3. Karşı taraftaki değişiklikler buraya iner.
    if (result.localChanged) {
      await _applyLocal(accountId, result.merged, local);
    }

    // 4. Buradaki değişiklikler (ve birleştirme farkı) sunucuya gider.
    final full = SettingsData(
      labels: {...result.merged.labels, ...split.skipped.labels},
      signatures: {...result.merged.signatures, ...split.skipped.signatures},
    );
    final hasAny = full.labels.isNotEmpty || full.signatures.isNotEmpty;
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
    }

    await _state.write(
      accountId,
      SettingsSyncState(baseJson: jsonEncode(result.merged.toJson()), rev: rev),
    );
    return okVoid;
  }

  static const int _maxDocuments = 20;

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
        if (box.specialUse == SpecialUse.inbox || box.path.toUpperCase() == 'INBOX') {
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
        final exists = again is Ok<List<RemoteMailbox>> &&
            again.value.any((b) => isSettingsMailbox(b.path, b.delimiter));
        if (!exists) return created;
      }
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

  Future<_Local> _readLocal(int accountId) async {
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
    return _Local(
      data: SettingsData(labels: labelRecords, signatures: sigRecords),
      labelsByKey: labelsByKey,
      signaturesByKey: sigsByKey,
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
      final ok = name is String &&
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
      final ok = r['name'] is String &&
          (r['name']! as String).trim().isNotEmpty &&
          r['body'] is String &&
          r['isDefault'] is bool;
      (ok ? sigs : skippedSigs)[entry.key] = r;
    }
    return (
      view: SettingsData(labels: labels, signatures: sigs),
      skipped: SettingsData(labels: skippedLabels, signatures: skippedSigs),
    );
  }

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
        if (renameOk) namesInUse.add(name);
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
        final changed = existing.name != name ||
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
  });

  /// Karşı taraftan gelen görsel alanlar; yoksa ya da bu imzanın görseli bu cihazdaysa yerelin kendi değerleri korunur.
  ({String type, String? url, int width, String position}) _imageFields(
    SettingsRecord remote,
    SignatureRow? existing,
  ) {
    final hasLocalImage = existing?.imageType == 'local';
    final type = remote['imageType'];
    if (hasLocalImage || type is! String || (type != 'none' && type != 'remote')) {
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
      width: width is num && width > 0 ? width.toInt() : (existing?.imageWidth ?? 200),
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
  });

  final SettingsData data;
  final Map<String, LabelRow> labelsByKey;
  final Map<String, SignatureRow> signaturesByKey;
}
