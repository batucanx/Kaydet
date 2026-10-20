import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../domain/models/mail_filter.dart';
import '../../domain/models/mail_models.dart' show EmailAddress, SpecialUse;
import '../../domain/use_cases/filter_rules.dart';
import '../database/app_database.dart';

/// Kaydetme sonucu: ya kaydedilen filtre ya da neden olmadığı.
class FilterSaveResult {
  const FilterSaveResult.saved(MailFilter this.filter)
    : violations = const [],
      limitReached = false,
      notFound = false;
  const FilterSaveResult.invalid(this.violations)
    : filter = null,
      limitReached = false,
      notFound = false;
  const FilterSaveResult.limit()
    : filter = null,
      violations = const [],
      limitReached = true,
      notFound = false;
  const FilterSaveResult.missing()
    : filter = null,
      violations = const [],
      limitReached = false,
      notFound = true;

  final MailFilter? filter;
  final List<FilterViolation> violations;

  /// Hesap başına [filterMaxPerAccount] filtre sınırı dolu.
  final bool limitReached;

  /// Güncellenmek istenen filtre artık yok.
  final bool notFound;

  bool get ok => filter != null;
}

/// "Filtreyi test et" listesindeki bir ileti.
class FilterPreviewMessage {
  const FilterPreviewMessage({
    required this.id,
    required this.subject,
    required this.sender,
    required this.date,
  });

  final int id;
  final String subject;
  final String sender;
  final DateTime date;
}

/// Hesabın gelen e-posta filtreleri deposu (yerel veritabanı).
///
/// Arayüzün kullandığı değişiklikler ([add], [update], [setEnabled], [delete], [reorder]) [onChanged] ile ayar belgesinin
/// yakında eşitlenmesini ister (diğer ayarlar gibi). Eşitleme motorunun kullandığı [put] ve [removeById] istemez.
/// Filtreler YALNIZCA saklanır: gelen postaya uygulama bu sınıfın (ve telefonun) işi değildir.
class MailFilterRepository {
  MailFilterRepository({
    required AppDatabase database,
    this.onChanged,
    DateTime Function()? now,
    String Function()? newId,
  }) : _db = database,
       _now = now ?? DateTime.now,
       _newId = newId ?? generateFilterId;

  final AppDatabase _db;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Yerelde bir filtre değişti: ayar belgesi yakında eşitlensin.
  final void Function(int accountId)? onChanged;

  $MailFiltersTable get _table => _db.mailFilters;

  // ------------------------------------------------------------------ okuma

  Stream<List<MailFilter>> watch(int accountId) =>
      (_db.select(_table)
            ..where((f) => f.accountId.equals(accountId))
            ..orderBy([
              (f) => OrderingTerm.asc(f.position),
              (f) => OrderingTerm.asc(f.id),
            ]))
          .watch()
          .map((rows) => [for (final r in rows) filterOfRow(r)]);

  /// Çalışma sırasıyla (`position`, sonra kimlik).
  Future<List<MailFilter>> list(int accountId) async {
    final rows =
        await (_db.select(_table)
              ..where((f) => f.accountId.equals(accountId))
              ..orderBy([
                (f) => OrderingTerm.asc(f.position),
                (f) => OrderingTerm.asc(f.id),
              ]))
            .get();
    return [for (final r in rows) filterOfRow(r)];
  }

  Future<MailFilter?> byId(int accountId, String id) async {
    final row =
        await (_db.select(_table)
              ..where((f) => f.accountId.equals(accountId) & f.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : filterOfRow(row);
  }

  Future<int> count(int accountId) async {
    final c = _table.id.count();
    final row =
        await (_db.selectOnly(_table)
              ..addColumns([c])
              ..where(_table.accountId.equals(accountId)))
            .getSingle();
    return row.read(c) ?? 0;
  }

  // -------------------------------------------------------- arayüz değişiklikleri

  /// Yeni filtreyi listenin SONUNA ekler. [ownAddresses]: hesabın kendi adresleri (kendine iletme reddedilir).
  Future<FilterSaveResult> add(
    int accountId,
    FilterDefinition input, {
    Set<String> ownAddresses = const {},
  }) async {
    final definition = _named(input);
    final violations = validateFilterForSave(
      definition,
      ownAddresses: ownAddresses,
    );
    if (violations.isNotEmpty) return FilterSaveResult.invalid(violations);
    final result = await _db.transaction(() async {
      if (await count(accountId) >= filterMaxPerAccount) {
        return const FilterSaveResult.limit();
      }
      final maxPosition = _table.position.max();
      final last =
          await (_db.selectOnly(_table)
                ..addColumns([maxPosition])
                ..where(_table.accountId.equals(accountId)))
              .map((r) => r.read(maxPosition))
              .getSingle();
      var id = _newId();
      while (await byId(accountId, id) != null) {
        id = _newId();
      }
      final now = _now();
      await _db
          .into(_table)
          .insert(
            _companion(
              accountId,
              id,
              definition,
              position: last == null ? 0 : last + 1,
              createdAt: now,
              updatedAt: now,
            ),
          );
      return FilterSaveResult.saved((await byId(accountId, id))!);
    });
    if (result.ok) onChanged?.call(accountId);
    return result;
  }

  /// Var olan filtrenin tanımını değiştirir; sırası ve oluşturulma zamanı korunur.
  Future<FilterSaveResult> update(
    int accountId,
    String id,
    FilterDefinition input, {
    Set<String> ownAddresses = const {},
  }) async {
    final definition = _named(input);
    final violations = validateFilterForSave(
      definition,
      ownAddresses: ownAddresses,
    );
    if (violations.isNotEmpty) return FilterSaveResult.invalid(violations);
    final existing = await byId(accountId, id);
    if (existing == null) return const FilterSaveResult.missing();
    await (_db.update(
      _table,
    )..where((f) => f.accountId.equals(accountId) & f.id.equals(id))).write(
      _companion(
        accountId,
        id,
        definition,
        position: existing.position,
        createdAt: existing.createdAt,
        updatedAt: _now(),
      ),
    );
    onChanged?.call(accountId);
    return FilterSaveResult.saved((await byId(accountId, id))!);
  }

  Future<bool> setEnabled(int accountId, String id, bool enabled) async {
    final changed =
        await (_db.update(
          _table,
        )..where((f) => f.accountId.equals(accountId) & f.id.equals(id))).write(
          MailFiltersCompanion(
            enabled: Value(enabled),
            updatedAt: Value(_now()),
          ),
        );
    if (changed > 0) onChanged?.call(accountId);
    return changed > 0;
  }

  Future<bool> delete(int accountId, String id) async {
    final removed = await removeById(accountId, id);
    if (removed) onChanged?.call(accountId);
    return removed;
  }

  /// Çalışma sırasını [orderedIds] yapar (0..n-1). Listede olmayan yerel filtreler eski sırasıyla sona gider.
  Future<void> reorder(int accountId, List<String> orderedIds) async {
    final changed = await _db.transaction(() async {
      final current = await list(accountId);
      final byId = {for (final f in current) f.id: f};
      final order = <String>[
        for (final id in orderedIds)
          if (byId.containsKey(id)) id,
      ];
      for (final f in current) {
        if (!order.contains(f.id)) order.add(f.id);
      }
      var any = false;
      for (var i = 0; i < order.length; i++) {
        if (byId[order[i]]!.position == i) continue;
        any = true;
        await (_db.update(_table)..where(
              (f) => f.accountId.equals(accountId) & f.id.equals(order[i]),
            ))
            .write(
              MailFiltersCompanion(
                position: Value(i),
                updatedAt: Value(_now()),
              ),
            );
      }
      return any;
    });
    if (changed) onChanged?.call(accountId);
  }

  // ------------------------------------------------------------ eşitleme

  /// Belgeden gelen (ya da değişen) filtreyi AYNI kimlikle yazar. [definition] belgeden çözülmüş ve doğrulanmış olmalıdır;
  /// burada yeniden doğrulanmaz. Eşitlemeyi tetiklemez.
  Future<void> put(
    int accountId,
    String id,
    FilterDefinition definition, {
    required int position,
  }) async {
    final existing = await byId(accountId, id);
    final now = _now();
    await _db
        .into(_table)
        .insertOnConflictUpdate(
          _companion(
            accountId,
            id,
            definition,
            position: position,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
          ),
        );
  }

  /// Eşitlemeyi tetiklemeden siler.
  Future<bool> removeById(int accountId, String id) async =>
      await (_db.delete(
        _table,
      )..where((f) => f.accountId.equals(accountId) & f.id.equals(id))).go() >
      0;

  // ------------------------------------------------- "filtreyi test et" önizlemesi

  /// Gelen Kutusu'ndaki son iletiler (yerel önbellekten, en yeni önce): filtreyi denemek için. Hiçbir şey okunmaz/değiştirilmez
  /// ve ağa çıkılmaz.
  Future<List<FilterPreviewMessage>> previewMessages(
    int accountId, {
    int limit = 30,
  }) async {
    final inboxIds = [
      for (final box in await _db.mailboxesOf(accountId))
        if (box.specialUse == SpecialUse.inbox) box.id,
    ];
    if (inboxIds.isEmpty) return const [];
    final rows =
        await (_db.select(_db.messages)
              ..where(
                (m) =>
                    m.accountId.equals(accountId) &
                    m.mailboxId.isIn(inboxIds) &
                    m.isDraft.equals(false) &
                    m.isDeleted.equals(false),
              )
              ..orderBy([(m) => OrderingTerm.desc(m.dateUtc)])
              ..limit(limit))
            .get();
    return [
      for (final row in rows)
        FilterPreviewMessage(
          id: row.id,
          subject: row.subject,
          sender: row.fromName.trim().isNotEmpty ? row.fromName : row.fromEmail,
          date: row.dateUtc,
        ),
    ];
  }

  /// İletinin filtrenin baktığı hâli. Gövde YALNIZCA cihazda önbellekteyse okunur ([withBody] ise); yoksa `null` kalır ve
  /// gövde koşulları eşleşmez (web'deki "gövde okunamadı" ile aynı).
  Future<FilterableMail?> loadFilterableMail(
    int messageId, {
    bool withBody = false,
  }) async {
    final row = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (row == null) return null;
    FilterableAddress addr(EmailAddress a) =>
        FilterableAddress(email: a.email, name: a.name ?? '');
    String? body;
    if (withBody) {
      final stored = await _db.bodyOf(messageId);
      body = _readableText(stored?.plainText, stored?.html);
    }
    return FilterableMail(
      from: FilterableAddress(email: row.fromEmail, name: row.fromName),
      to: [for (final a in EmailAddress.decodeList(row.toAddrJson)) addr(a)],
      cc: [for (final a in EmailAddress.decodeList(row.ccJson)) addr(a)],
      subject: row.subject,
      hasAttachments: row.hasAttachments,
      body: body,
    );
  }

  static String? _readableText(String? plain, String? html) {
    var text = plain;
    if (text == null || text.trim().isEmpty) {
      if (html == null || html.trim().isEmpty) return null;
      text = html
          .replaceAll(
            RegExp(
              r'<(script|style)[^>]*>.*?</\1>',
              caseSensitive: false,
              dotAll: true,
            ),
            ' ',
          )
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&amp;', '&')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return text.length > filterBodySearchLimit
        ? text.substring(0, filterBodySearchLimit)
        : text;
  }

  // ---------------------------------------------------------------- yardımcı

  /// Adı boş bırakılan filtreyi ilk koşuldan adlandırır (web sunucusuyla aynı: "" = adı sistem koysun). Belgeden gelen
  /// ([put]) ad olduğu gibi saklanır.
  FilterDefinition _named(FilterDefinition d) => d.name.trim().isNotEmpty
      ? d
      : FilterDefinition(
          name: defaultFilterName(
            d.conditions,
          ).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim(),
          enabled: d.enabled,
          matchMode: d.matchMode,
          conditions: d.conditions,
          actions: d.actions,
          stopProcessing: d.stopProcessing,
        );

  MailFiltersCompanion _companion(
    int accountId,
    String id,
    FilterDefinition definition, {
    required int position,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) => MailFiltersCompanion(
    id: Value(id),
    accountId: Value(accountId),
    name: Value(definition.name.trim()),
    enabled: Value(definition.enabled),
    position: Value(position),
    matchMode: Value(definition.matchMode.name),
    conditionsJson: Value(
      jsonEncode([
        for (final c in definition.conditions)
          FilterCondition(
            field: c.field,
            operator: c.operator,
            value: c.hasValue ? c.value.trim() : '',
          ).toJson(),
      ]),
    ),
    actionsJson: Value(
      jsonEncode([
        for (final a in definition.actions)
          (a.type == FilterActionType.forward
                  ? FilterAction.forward(
                      normalizeMailAddress(a.email) ?? (a.email ?? '').trim(),
                    )
                  : a)
              .toJson(),
      ]),
    ),
    stopProcessing: Value(definition.stopProcessing),
    createdAt: Value(createdAt),
    updatedAt: Value(updatedAt),
  );

  /// Satırı modele çevirir. Bozuk bir koşul/eylem kaydı atlanır (satır yine listelenir; düzenlenip kaydedilince düzelir).
  static MailFilter filterOfRow(MailFilterRow row) {
    List<T> decode<T>(String json, T? Function(Object?) parse) {
      try {
        final raw = jsonDecode(json);
        if (raw is! List) return const [];
        return [
          for (final item in raw)
            if (parse(item) case final T value) value,
        ];
      } on FormatException {
        return const [];
      }
    }

    return MailFilter(
      id: row.id,
      accountId: row.accountId,
      name: row.name,
      enabled: row.enabled,
      position: row.position,
      matchMode: row.matchMode == 'any'
          ? FilterMatchMode.any
          : FilterMatchMode.all,
      conditions: decode(row.conditionsJson, FilterCondition.fromJson),
      actions: decode(row.actionsJson, FilterAction.fromJson),
      stopProcessing: row.stopProcessing,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}

/// Web'de çakışmayan benzersiz filtre kimliği: UUID v4 biçimi (128 bit rastgelelik).
String generateFilterId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
