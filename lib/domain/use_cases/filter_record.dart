/// Gelen e-posta filtresinin ayar belgesindeki (`filters`, belge v5) PAYLAŞILAN biçimi ve yerel filtreyle arasındaki çeviri.
///
/// KAYNAK: web `packages/domain/src/settings/filter-record.ts` (kayıt şeması) ve
/// `apps/server/src/application/services/settings-sync-filters.ts` (kayıt ↔ yerel, kullanılabilir/taşınan ayrımı).
/// Sözleşme: web deposunda `docs/SETTINGS-FILTERS-CONTRACT.md`.
///
/// Kayıt, cihazlar arasında taşınabilir adlarla konuşur, yerel kimlikle ASLA:
///  - klasör: IMAP yolu ayraçtan bölünmüş, ÇÖZÜLMÜŞ (UTF-7 değil) ad parçaları (`["INBOX","Faturalar"]`),
///  - etiket: `labels` koleksiyonunun anahtarı (IMAP anahtar kelimesi, `kaydet_fatura`),
///  - Spam / Çöp / Arşiv: klasörsüz, rolle.
///
/// Bir istemcinin O AN kullanamadığı kayıt (klasör/etiket yok, arayüzün reddedeceği kural, 100 üstü, bozuk biçim) belgede AYNEN
/// kalır, yerele yazılmaz, birleştirmenin atasına girmez: "taşınır, asla silinmez".
///
/// Saf Dart: veritabanı ya da ağ yok.
library;

import '../models/mail_models.dart' show SpecialUse;
import 'filter_rules.dart';
import 'settings_merge.dart';

/// Klasör yolu en çok bu kadar parça, parça en çok bu kadar karakter.
const int sharedFolderMaxSegments = 16;
const int sharedFolderSegmentMaxLength = 256;
const int sharedFilterMaxPosition = 1000000;

/// Belgedeki eylem: klasör parça dizisiyle, etiket anahtar kelimesiyle.
class SharedFilterAction {
  const SharedFilterAction(this.type, {this.folder, this.label, this.email});

  final FilterActionType type;
  final List<String>? folder;
  final String? label;
  final String? email;

  Map<String, Object?> toRecord() => switch (type) {
    FilterActionType.move => {
      'type': 'move',
      'folder': [...folder!],
    },
    FilterActionType.label => {'type': 'label', 'label': label},
    FilterActionType.forward => {'type': 'forward', 'email': email},
    _ => {'type': type.name},
  };
}

class SharedFilter {
  const SharedFilter({
    required this.name,
    required this.enabled,
    required this.position,
    required this.matchMode,
    required this.conditions,
    required this.actions,
    required this.stopProcessing,
  });

  final String name;
  final bool enabled;
  final int position;
  final FilterMatchMode matchMode;
  final List<FilterCondition> conditions;
  final List<SharedFilterAction> actions;
  final bool stopProcessing;
}

SharedFilterAction? _parseSharedAction(Object? raw) {
  if (raw is! Map) return null;
  final type = raw['type'];
  if (type is! String) return null;
  switch (type) {
    case 'move':
      final folder = raw['folder'];
      if (folder is! List ||
          folder.isEmpty ||
          folder.length > sharedFolderMaxSegments) {
        return null;
      }
      final segments = <String>[];
      for (final s in folder) {
        if (s is! String ||
            s.isEmpty ||
            s.length > sharedFolderSegmentMaxLength) {
          return null;
        }
        segments.add(s);
      }
      return SharedFilterAction(FilterActionType.move, folder: segments);
    case 'label':
      final label = raw['label'];
      if (label is! String || label.isEmpty || label.length > 256) return null;
      return SharedFilterAction(FilterActionType.label, label: label);
    case 'forward':
      final email = raw['email'];
      if (email is! String) return null;
      final trimmed = email.trim();
      if (trimmed.length < 3 || trimmed.length > 320) return null;
      return SharedFilterAction(FilterActionType.forward, email: trimmed);
    case 'spam':
      return const SharedFilterAction(FilterActionType.spam);
    case 'trash':
      return const SharedFilterAction(FilterActionType.trash);
    case 'archive':
      return const SharedFilterAction(FilterActionType.archive);
    case 'delete':
      return const SharedFilterAction(FilterActionType.delete);
  }
  return null;
}

/// Kaydın tanımladığı filtre; bu kodun kullanabileceği biçimde (ya da artık) değilse `null`. Tanınmayan eylem/koşul
/// kaydı BÜTÜNÜYLE kullanılamaz yapar: yarım uygulanmaz, olduğu gibi taşınır. KAYNAK: web `parseSharedFilter`.
SharedFilter? parseSharedFilter(SettingsRecord record) {
  final name = record['name'];
  if (name is! String) return null;
  final trimmedName = name.trim();
  if (trimmedName.length > filterNameMaxLength ||
      hasControlCharacter(trimmedName)) {
    return null;
  }
  final enabled = record['enabled'];
  if (enabled is! bool) return null;
  final rawPosition = record['position'];
  if (rawPosition is! num ||
      !rawPosition.isFinite ||
      rawPosition != rawPosition.truncate() ||
      rawPosition < 0 ||
      rawPosition > sharedFilterMaxPosition) {
    return null;
  }
  final matchMode = switch (record['matchMode']) {
    'all' => FilterMatchMode.all,
    'any' => FilterMatchMode.any,
    _ => null,
  };
  if (matchMode == null) return null;
  final rawConditions = record['conditions'];
  if (rawConditions is! List ||
      rawConditions.isEmpty ||
      rawConditions.length > filterMaxConditions) {
    return null;
  }
  final conditions = <FilterCondition>[];
  for (final raw in rawConditions) {
    final c = FilterCondition.fromJson(raw);
    if (c == null) return null;
    conditions.add(c);
  }
  final rawActions = record['actions'];
  if (rawActions is! List ||
      rawActions.isEmpty ||
      rawActions.length > filterMaxActions) {
    return null;
  }
  final actions = <SharedFilterAction>[];
  for (final raw in rawActions) {
    final a = _parseSharedAction(raw);
    if (a == null) return null;
    actions.add(a);
  }
  final stop = record['stopProcessing'];
  if (stop is! bool) return null;
  return SharedFilter(
    name: trimmedName,
    enabled: enabled,
    position: rawPosition.toInt(),
    matchMode: matchMode,
    conditions: conditions,
    actions: actions,
    stopProcessing: stop,
  );
}

/// Yazılan kayıt: sabit alan sırası, her eylem tam kendi alanlarıyla.
SettingsRecord sharedFilterRecord(SharedFilter filter) => {
  'name': filter.name,
  'enabled': filter.enabled,
  'position': filter.position,
  'matchMode': filter.matchMode.name,
  'conditions': [for (final c in filter.conditions) c.toJson()],
  'actions': [for (final a in filter.actions) a.toRecord()],
  'stopProcessing': filter.stopProcessing,
};

// ── Klasör adları ────────────────────────────────────────────────────────────

/// Posta kutusu yolunun ayraçtan bölünmüş parçaları: `INBOX.Faturalar` (ayraç `.`) da `INBOX/Faturalar` (ayraç `/`) da
/// `["INBOX","Faturalar"]`. Ayraçsız sunucuda tek parça. [path] ÇÖZÜLMÜŞ yoldur (`Mailboxes.path`, UTF-7 değil).
List<String> folderSegments(String path, String delimiter) =>
    delimiter.isEmpty ? [path] : path.split(delimiter);

/// Yol parçalarını karşılaştırmak/indekslemek için tek dizgeye çevirir (parça NUL içermez).
String folderPathKey(List<String> segments) => segments.join('\u0000');

/// Hesabın klasörleri, kaydın kullandığı kararlı adla (yolun ayraçtan bölünmüş hâli).
class FolderIndex {
  const FolderIndex({
    required this.idByKey,
    required this.pathById,
    required this.roleById,
    required this.inboxId,
  });

  final Map<String, int> idByKey;
  final Map<int, List<String>> pathById;
  final Map<int, SpecialUse> roleById;
  final int? inboxId;

  /// Klasör satırlarından (`id`, çözülmüş `path`, `delimiter`, `specialUse`).
  factory FolderIndex.of(
    Iterable<({int id, String path, String delimiter, SpecialUse role})> rows,
  ) {
    final idByKey = <String, int>{};
    final pathById = <int, List<String>>{};
    final roleById = <int, SpecialUse>{};
    int? inboxId;
    for (final row in rows) {
      roleById[row.id] = row.role;
      if (row.role == SpecialUse.inbox) inboxId = row.id;
      final segments = folderSegments(row.path, row.delimiter);
      pathById[row.id] = segments;
      idByKey[folderPathKey(segments)] = row.id;
    }
    return FolderIndex(
      idByKey: idByKey,
      pathById: pathById,
      roleById: roleById,
      inboxId: inboxId,
    );
  }
}

/// `move` hedefi olabilen klasör rolü: elle taşımayla AYNI kural (Taslak, Gönderilmiş, Çöp, İstenmeyen ve Gelen Kutusu'nun
/// kendisi hedef olamaz; ayrı eylemleri vardır). KAYNAK: web `canMoveMail`.
bool canFilterMoveInto(SpecialUse role) =>
    role == SpecialUse.archive || role == SpecialUse.custom;

// ── Yerel filtre → kayıt ─────────────────────────────────────────────────────

/// Yerel filtrenin kaydı; klasörü ya da etiketi bu hesapta artık yoksa (ya da değer paylaşılan sınırların dışındaysa)
/// `null`. Çağıran o zaman belgenin o filtre için zaten söylediğini korur.
SettingsRecord? toSharedRecord(
  FilterDefinition filter,
  int position, {
  required Map<int, List<String>> folderPathById,
  required Map<int, String> labelKeyById,
}) {
  final actions = <SharedFilterAction>[];
  for (final action in filter.actions) {
    switch (action.type) {
      case FilterActionType.move:
        final path = folderPathById[action.folderId];
        if (path == null) return null;
        actions.add(
          SharedFilterAction(FilterActionType.move, folder: [...path]),
        );
      case FilterActionType.label:
        final key = labelKeyById[action.labelId];
        if (key == null) return null;
        actions.add(SharedFilterAction(FilterActionType.label, label: key));
      case FilterActionType.forward:
        actions.add(
          SharedFilterAction(FilterActionType.forward, email: action.email),
        );
      default:
        actions.add(SharedFilterAction(action.type));
    }
  }
  final record = sharedFilterRecord(
    SharedFilter(
      name: filter.name,
      enabled: filter.enabled,
      position: position,
      matchMode: filter.matchMode,
      conditions: filter.conditions,
      actions: actions,
      stopProcessing: filter.stopProcessing,
    ),
  );
  return parseSharedFilter(record) == null ? null : record;
}

// ── Kayıt → yerel filtre ─────────────────────────────────────────────────────

/// Bu hesabın sakladığı biçimde bir filtre.
class ResolvedFilter {
  const ResolvedFilter({required this.definition, required this.position});

  final FilterDefinition definition;
  final int position;
}

class ResolveRefs {
  const ResolveRefs({
    required this.folders,
    required this.labelIdOf,
    required this.ownAddress,
  });

  final FolderIndex folders;

  /// Bu anahtar kelimeli etiketin yerel kimliği; hesapta yoksa `null`.
  final int? Function(String key) labelIdOf;

  /// Hesabın kendi adresi: filtre ona iletemez.
  final String? ownAddress;
}

sealed class Resolution {
  const Resolution();
}

class ResolvedOk extends Resolution {
  const ResolvedOk(this.filter);
  final ResolvedFilter filter;
}

/// Bu istemci kaydı OLDUĞU GİBİ asla kullanmayacak (tanınmayan eylem, burada izin verilmeyen kural).
class ResolvedInvalid extends Resolution {
  const ResolvedInvalid();
}

/// Kullanılabilir hâle GELEBİLİR (klasör ya da etiket henüz yok).
class ResolvedUnresolved extends Resolution {
  const ResolvedUnresolved();
}

/// KAYNAK: web `resolveSharedRecord`. Ad boşsa boş KALIR (web yerele türetilmiş adı yazar; telefon belgedekini korur, böylece
/// belgeye geri yazılan kayıt değişmez — arayüz `MailFilter.displayName` ile türetilmiş adı gösterir).
Resolution resolveSharedRecord(SettingsRecord record, ResolveRefs refs) {
  final shared = parseSharedFilter(record);
  if (shared == null) return const ResolvedInvalid();

  var unresolved = false;
  var invalid = false;
  final actions = <FilterAction>[];
  for (final action in shared.actions) {
    switch (action.type) {
      case FilterActionType.move:
        final folderId = refs.folders.idByKey[folderPathKey(action.folder!)];
        final role = folderId == null ? null : refs.folders.roleById[folderId];
        if (folderId == null || role == null || refs.folders.inboxId == null) {
          unresolved = true;
        } else {
          // Elle taşımayla aynı kurallar: Taslak, Gönderilmiş, Çöp, İstenmeyen ve Gelen Kutusu yok.
          if (!canFilterMoveInto(role)) invalid = true;
          actions.add(FilterAction.move(folderId));
        }
      case FilterActionType.label:
        final labelId = refs.labelIdOf(action.label!);
        if (labelId == null) {
          unresolved = true;
        } else {
          actions.add(FilterAction.label(labelId));
        }
      case FilterActionType.forward:
        actions.add(
          FilterAction.forward(
            normalizeMailAddress(action.email) ?? action.email!,
          ),
        );
      default:
        actions.add(FilterAction.blank(action.type));
    }
  }
  final own = refs.ownAddress;
  if (invalid ||
      validateFilterDefinition(
        actions,
        own == null ? const {} : {own},
      ).isNotEmpty) {
    return const ResolvedInvalid();
  }
  if (unresolved) return const ResolvedUnresolved();
  return ResolvedOk(
    ResolvedFilter(
      position: shared.position,
      definition: FilterDefinition(
        name: shared.name,
        enabled: shared.enabled,
        matchMode: shared.matchMode,
        conditions: shared.conditions,
        actions: actions,
        stopProcessing: shared.stopProcessing,
      ),
    ),
  );
}

class FilterPartition {
  const FilterPartition({
    required this.applicable,
    required this.resolved,
    required this.deferred,
  });

  /// Bu hesabın şimdi kullanabildiği kayıtlar.
  final SettingsCollection applicable;
  final Map<String, ResolvedFilter> resolved;

  /// Geri kalan her şey: belgede taşınır, burada uygulanmaz.
  final SettingsCollection deferred;
}

double _rank(SettingsRecord record) {
  final p = record['position'];
  return p is num && p.isFinite ? p.toDouble() : double.infinity;
}

/// Belgenin kayıtlarını kullanılabilir ve taşınan diye ayırır. Hesap en çok [filterMaxPerAccount] filtre tutar: çalışma
/// sırasındaki ilkler.
FilterPartition partitionFilters(
  SettingsCollection records,
  Resolution Function(SettingsRecord record) resolve,
) {
  final applicable = <String, SettingsRecord>{};
  final deferred = <String, SettingsRecord>{};
  final resolved = <String, ResolvedFilter>{};
  final keys = records.keys.toList()
    ..sort((a, b) {
      final ra = _rank(records[a]!);
      final rb = _rank(records[b]!);
      if (ra != rb) return ra < rb ? -1 : 1;
      return a.compareTo(b);
    });
  for (final key in keys) {
    final record = records[key]!;
    final result = resolve(record);
    if (result is ResolvedOk && resolved.length < filterMaxPerAccount) {
      applicable[key] = record;
      resolved[key] = result.filter;
    } else {
      deferred[key] = record;
    }
  }
  return FilterPartition(
    applicable: applicable,
    resolved: resolved,
    deferred: deferred,
  );
}

String _conditionKey(FilterCondition c) =>
    '${c.field.name}|${c.operator.name}|${c.hasValue ? c.value : ''}';

String _actionKey(FilterAction a) =>
    '${a.type.name}|${switch (a.type) {
      FilterActionType.move => a.folderId,
      FilterActionType.label => a.labelId,
      FilterActionType.forward => a.email,
      _ => '',
    }}';

/// Saklı filtre, çözülmüş olanın söylediğini zaten söylüyor mu (arayüzün düzenlediği her şey ve çalışma sırasındaki yeri)?
bool sameFilterDefinition(
  FilterDefinition stored,
  int storedPosition,
  ResolvedFilter next,
) {
  final n = next.definition;
  return stored.name == n.name &&
      stored.enabled == n.enabled &&
      storedPosition == next.position &&
      stored.matchMode == n.matchMode &&
      stored.stopProcessing == n.stopProcessing &&
      stored.conditions.map(_conditionKey).join('\n') ==
          n.conditions.map(_conditionKey).join('\n') &&
      stored.actions.map(_actionKey).join('\n') ==
          n.actions.map(_actionKey).join('\n');
}
