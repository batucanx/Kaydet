/// Gelen e-posta filtreleri: tanım (koşullar, eylemler), doğrulama kuralları, değerlendirici ve varsayılan ad.
///
/// KAYNAK: web projesindeki `packages/domain/src/filters/filters.ts` (şema + `validateFilterDefinition` + `evaluateFilter` +
/// `defaultFilterName`). İki gerçekleme AYNI davranmak ZORUNDADIR; ortak test tablosu `test/fixtures/filter_vectors.json`
/// (web'deki `filters/vectors.json`un kopyası).
///
/// DİKKAT: telefon filtreleri yalnızca listeler, düzenler, eşitler ve "filtreyi test et" önizlemesinde DEĞERLENDİRİR.
/// Gelen postaya UYGULAMAZ (çift çalıştırma koruması gelene kadar; bkz. web `docs/SETTINGS-FILTERS-CONTRACT.md`).
///
/// Saf Dart: giriş/çıkış yok, saat yok.
library;

import '../../core/turkish.dart';
import '../models/mail_models.dart' show EmailAddress;

// ── Sınırlar ─────────────────────────────────────────────────────────────────

const int filterNameMaxLength = 100;
const int filterValueMaxLength = 200;
const int filterMaxConditions = 10;
const int filterMaxActions = 10;

/// Bir filtre en çok tek adrese iletir (Yandex Mail gibi).
const int filterMaxForwards = 1;

/// Hesap başına filtre sayısı.
const int filterMaxPerAccount = 100;

/// "İçerik" koşulunun aradığı gövde uzunluğu.
const int filterBodySearchLimit = 200000;

/// Satır sonu, sekme ve diğer denetim karakterleri (tek satırlık ad, günlük satırı ya da başlıkta yeri yok).
bool hasControlCharacter(String text) {
  for (final rune in text.runes) {
    if (rune < 32 || rune == 127) return true;
  }
  return false;
}

// ── Koşullar ─────────────────────────────────────────────────────────────────

enum FilterField { from, to, cc, address, subject, body, attachment }

enum FilterOperator {
  equals,
  contains,
  notContains,
  startsWith,
  endsWith,
  exists,
  notExists,
}

const List<FilterField> addressFilterFields = [
  FilterField.from,
  FilterField.to,
  FilterField.cc,
  FilterField.address,
];
const List<FilterField> textFilterFields = [
  FilterField.subject,
  FilterField.body,
];

/// Bir alanın sunduğu işleçler, menü sırasıyla.
List<FilterOperator> operatorsFor(FilterField field) {
  switch (field) {
    case FilterField.attachment:
      return const [FilterOperator.exists, FilterOperator.notExists];
    case FilterField.subject:
    case FilterField.body:
      return const [
        FilterOperator.equals,
        FilterOperator.contains,
        FilterOperator.notContains,
        FilterOperator.startsWith,
        FilterOperator.endsWith,
      ];
    case FilterField.from:
    case FilterField.to:
    case FilterField.cc:
    case FilterField.address:
      return const [FilterOperator.equals, FilterOperator.contains];
  }
}

class FilterCondition {
  const FilterCondition({
    required this.field,
    required this.operator,
    this.value = '',
  });

  final FilterField field;
  final FilterOperator operator;

  /// Ek dosyası koşullarında boştur.
  final String value;

  bool get hasValue => field != FilterField.attachment;

  FilterCondition copyWith({
    FilterField? field,
    FilterOperator? operator,
    String? value,
  }) => FilterCondition(
    field: field ?? this.field,
    operator: operator ?? this.operator,
    value: value ?? this.value,
  );

  /// Belge/veritabanı biçimi (web `FilterCondition` ile aynı alanlar).
  Map<String, Object?> toJson() => {
    'field': field.name,
    'operator': operator.name,
    if (hasValue) 'value': value,
  };

  /// Web şemasına (`FilterConditionSchema`, strictObject) BİREBİR uyan koşul; uymayan `null`.
  static FilterCondition? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final field = _enumByName(FilterField.values, raw['field']);
    final operator = _enumByName(FilterOperator.values, raw['operator']);
    if (field == null || operator == null) return null;
    if (!operatorsFor(field).contains(operator)) return null;
    if (field == FilterField.attachment) {
      if (raw.length != 2) return null;
      return FilterCondition(field: field, operator: operator);
    }
    if (raw.length != 3) return null;
    final value = raw['value'];
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > filterValueMaxLength) return null;
    return FilterCondition(field: field, operator: operator, value: trimmed);
  }

  @override
  bool operator ==(Object other) =>
      other is FilterCondition &&
      other.field == field &&
      other.operator == operator &&
      other.value == value;

  @override
  int get hashCode => Object.hash(field, operator, value);
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

enum FilterMatchMode { all, any }

// ── Eylemler ─────────────────────────────────────────────────────────────────

/// `delete` KALICI siler; `trash` geri alınabilir "Çöp kutusuna taşı"dır.
enum FilterActionType { move, forward, label, spam, trash, archive, delete }

/// Gelen Kutusu'ndan çıkaran eylemler. Bir filtre en çok birini taşır.
const Set<FilterActionType> relocatingActions = {
  FilterActionType.move,
  FilterActionType.spam,
  FilterActionType.trash,
  FilterActionType.archive,
  FilterActionType.delete,
};

/// Yerel kimliklerle (klasör satır no, etiket satır no) bir eylem. Belgeye yazılırken kimlikler taşınabilir adlara çevrilir
/// (bkz. `filter_record.dart`).
class FilterAction {
  const FilterAction._(this.type, {this.folderId, this.labelId, this.email});

  const FilterAction.move(int folderId)
    : this._(FilterActionType.move, folderId: folderId);
  const FilterAction.label(int labelId)
    : this._(FilterActionType.label, labelId: labelId);
  const FilterAction.forward(String email)
    : this._(FilterActionType.forward, email: email);
  const FilterAction.spam() : this._(FilterActionType.spam);
  const FilterAction.trash() : this._(FilterActionType.trash);
  const FilterAction.archive() : this._(FilterActionType.archive);
  const FilterAction.delete() : this._(FilterActionType.delete);

  /// Henüz değer seçilmemiş boş eylem (düzenleyicide). `move`/`label` için kimlik 0, `forward` için boş adres.
  factory FilterAction.blank(FilterActionType type) {
    switch (type) {
      case FilterActionType.move:
        return const FilterAction.move(0);
      case FilterActionType.label:
        return const FilterAction.label(0);
      case FilterActionType.forward:
        return const FilterAction.forward('');
      case FilterActionType.spam:
        return const FilterAction.spam();
      case FilterActionType.trash:
        return const FilterAction.trash();
      case FilterActionType.archive:
        return const FilterAction.archive();
      case FilterActionType.delete:
        return const FilterAction.delete();
    }
  }

  final FilterActionType type;
  final int? folderId;
  final int? labelId;
  final String? email;

  bool get isRelocating => relocatingActions.contains(type);

  Map<String, Object?> toJson() => {
    'type': type.name,
    if (type == FilterActionType.move) 'folderId': folderId,
    if (type == FilterActionType.label) 'labelId': labelId,
    if (type == FilterActionType.forward) 'email': email,
  };

  static FilterAction? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = _enumByName(FilterActionType.values, raw['type']);
    if (type == null) return null;
    switch (type) {
      case FilterActionType.move:
        final id = raw['folderId'];
        return id is int ? FilterAction.move(id) : null;
      case FilterActionType.label:
        final id = raw['labelId'];
        return id is int ? FilterAction.label(id) : null;
      case FilterActionType.forward:
        final email = raw['email'];
        return email is String ? FilterAction.forward(email) : null;
      default:
        return FilterAction.blank(type);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FilterAction &&
      other.type == type &&
      other.folderId == folderId &&
      other.labelId == labelId &&
      other.email == email;

  @override
  int get hashCode => Object.hash(type, folderId, labelId, email);
}

// ── Tanım (kullanıcının düzenlediği şey) ─────────────────────────────────────

class FilterDefinition {
  const FilterDefinition({
    required this.name,
    required this.enabled,
    required this.matchMode,
    required this.conditions,
    required this.actions,
    required this.stopProcessing,
  });

  /// Boş = adı ilk koşuldan türet ([defaultFilterName]).
  final String name;
  final bool enabled;
  final FilterMatchMode matchMode;
  final List<FilterCondition> conditions;
  final List<FilterAction> actions;

  /// "Bu filtre eşleştiğinde diğer filtreleri çalıştırma".
  final bool stopProcessing;
}

enum FilterViolationReason { invalid, duplicate, conflict, tooMany }

class FilterViolation {
  const FilterViolation(this.field, this.reason);

  /// Tanım içindeki nokta yolu (`actions.1`, `actions.0.email`, `conditions.0.value`).
  final String field;
  final FilterViolationReason reason;

  @override
  bool operator ==(Object other) =>
      other is FilterViolation &&
      other.field == field &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(field, reason);

  @override
  String toString() => '$field:${reason.name}';
}

final RegExp _angleAddress = RegExp(r'<([^<>]*)>\s*$');
final RegExp _bareAddress = RegExp(r'^[^\s@<>]+@[^\s@<>]+$');

/// Bir gönderen dizgesinin çıplak, küçük harfli adresi; yoksa `null`: `"Ad" <User@Example.com >`, `User@Example.com` ve
/// `mailto:user@example.com` hepsi `user@example.com` verir. KAYNAK: web `normalizeMailAddress`.
String? normalizeMailAddress(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  final angle = _angleAddress.firstMatch(value);
  if (angle != null) value = (angle.group(1) ?? '').trim();
  value = value
      .replaceFirst(RegExp(r'^mailto:', caseSensitive: false), '')
      .replaceAll(RegExp("^[\"']+|[\"']+\$"), '')
      .trim()
      .toLowerCase();
  return _bareAddress.hasMatch(value) ? value : null;
}

/// Şemanın söyleyemediği kurallar. Klasör/etiket sahipliği çağıranın işidir (hesabın klasörleri gerekir).
List<FilterViolation> validateFilterDefinition(
  List<FilterAction> actions, [
  Set<String> ownAddresses = const {},
]) {
  final violations = <FilterViolation>[];
  final seen = <String>{};
  var relocations = 0;
  var forwards = 0;
  for (var index = 0; index < actions.length; index++) {
    final action = actions[index];
    final path = 'actions.$index';
    if (action.isRelocating) {
      relocations++;
      if (relocations > 1) {
        violations.add(FilterViolation(path, FilterViolationReason.conflict));
      }
    }
    if (action.type == FilterActionType.forward) {
      forwards++;
      final address = normalizeMailAddress(action.email);
      if (address == null || !EmailAddress.isValidEmail(address)) {
        violations.add(
          FilterViolation('$path.email', FilterViolationReason.invalid),
        );
      } else if (ownAddresses.contains(address)) {
        violations.add(
          FilterViolation('$path.email', FilterViolationReason.invalid),
        );
      }
      if (forwards > filterMaxForwards) {
        violations.add(FilterViolation(path, FilterViolationReason.tooMany));
      }
    }
    final identity = switch (action.type) {
      FilterActionType.forward =>
        'forward:${normalizeMailAddress(action.email) ?? action.email}',
      FilterActionType.label => 'label:${action.labelId}',
      FilterActionType.move => 'move',
      _ => action.type.name,
    };
    if (!seen.add(identity)) {
      violations.add(FilterViolation(path, FilterViolationReason.duplicate));
    }
  }
  return violations;
}

// ── Değerlendirme ────────────────────────────────────────────────────────────

class FilterableAddress {
  const FilterableAddress({required this.email, this.name = ''});
  final String email;
  final String name;
}

/// Filtrenin baktığı şey. [body] okunamadıysa `null`'dır (gövde koşulu o zaman asla eşleşmez).
class FilterableMail {
  const FilterableMail({
    required this.from,
    this.to = const [],
    this.cc = const [],
    this.subject = '',
    this.hasAttachments = false,
    this.body,
  });

  final FilterableAddress from;
  final List<FilterableAddress> to;
  final List<FilterableAddress> cc;
  final String subject;
  final bool hasAttachments;
  final String? body;
}

class FilterEvaluation {
  const FilterEvaluation({required this.matched, required this.conditions});

  final bool matched;

  /// Koşul başına bir sonuç, sırayla.
  final List<bool> conditions;
}

bool _textMatches(FilterOperator operator, String haystack, String needle) {
  switch (operator) {
    case FilterOperator.equals:
      return haystack == needle;
    case FilterOperator.contains:
      return haystack.contains(needle);
    case FilterOperator.notContains:
      return !haystack.contains(needle);
    case FilterOperator.startsWith:
      return haystack.startsWith(needle);
    case FilterOperator.endsWith:
      return haystack.endsWith(needle);
    case FilterOperator.exists:
    case FilterOperator.notExists:
      return false;
  }
}

/// Adres, çıplak adresiyle ya da görünen adıyla eşleşir ("Ahmet'ten gelen" ikisiyle de çalışır).
bool _addressMatches(
  FilterOperator operator,
  FilterableAddress address,
  String needle,
) {
  final email = foldForSearch(
    normalizeMailAddress(address.email) ?? address.email.trim(),
  );
  final name = foldForSearch(address.name.trim());
  // "<ali@x.com>" ya da "mailto:ali@x.com" yazan adresi kastetmiştir.
  final wanted = normalizeMailAddress(needle) ?? needle;
  if (operator == FilterOperator.equals) {
    return email == wanted || (name.isNotEmpty && name == needle);
  }
  return email.contains(wanted) || (name.isNotEmpty && name.contains(needle));
}

bool _conditionMatches(FilterCondition condition, FilterableMail mail) {
  if (condition.field == FilterField.attachment) {
    return condition.operator == FilterOperator.exists
        ? mail.hasAttachments
        : !mail.hasAttachments;
  }
  final needle = foldForSearch(condition.value.trim());
  if (needle.isEmpty) return false;
  switch (condition.field) {
    case FilterField.subject:
      return _textMatches(
        condition.operator,
        foldForSearch(mail.subject),
        needle,
      );
    case FilterField.body:
      final body = mail.body;
      return body == null
          ? false
          : _textMatches(condition.operator, foldForSearch(body), needle);
    case FilterField.from:
      return _addressMatches(condition.operator, mail.from, needle);
    case FilterField.to:
      return mail.to.any((a) => _addressMatches(condition.operator, a, needle));
    case FilterField.cc:
      return mail.cc.any((a) => _addressMatches(condition.operator, a, needle));
    case FilterField.address:
      return [
        mail.from,
        ...mail.to,
        ...mail.cc,
      ].any((a) => _addressMatches(condition.operator, a, needle));
    case FilterField.attachment:
      return false;
  }
}

/// İleti koşulların HEPSİNİ (`all`) ya da HERHANGİ BİRİNİ (`any`) sağlıyor mu? Koşulsuz filtre asla eşleşmez.
FilterEvaluation evaluateFilter(
  FilterMatchMode matchMode,
  List<FilterCondition> conditions,
  FilterableMail mail,
) {
  final results = [for (final c in conditions) _conditionMatches(c, mail)];
  final matched =
      results.isNotEmpty &&
      (matchMode == FilterMatchMode.all
          ? results.every((r) => r)
          : results.any((r) => r));
  return FilterEvaluation(matched: matched, conditions: results);
}

/// Filtreyi değerlendirmek iletinin gövdesini gerektiriyor mu (sunucudan okuma maliyeti)?
bool filterNeedsBody(List<FilterCondition> conditions) =>
    conditions.any((c) => c.field == FilterField.body);

// ── Adlandırma ───────────────────────────────────────────────────────────────

String filterFieldName(FilterField field) => switch (field) {
  FilterField.from => 'Kimden',
  FilterField.to => 'Kime',
  FilterField.cc => 'CC',
  FilterField.address => 'E-posta adresi',
  FilterField.subject => 'Konu',
  FilterField.body => 'İçerik',
  FilterField.attachment => 'Ek dosyası',
};

/// Adı boş bırakılan filtrenin adı: ilk koşulu, örn. `Kimden: fatura@example.com`.
String defaultFilterName(List<FilterCondition> conditions) {
  if (conditions.isEmpty) return 'Filtre';
  final first = conditions.first;
  final text = first.field == FilterField.attachment
      ? (first.operator == FilterOperator.exists
            ? 'Ek dosyası var'
            : 'Ek dosyası yok')
      : '${filterFieldName(first.field)}: ${first.value}';
  final name = conditions.length > 1 ? '$text +${conditions.length - 1}' : text;
  // JS `slice` UTF-16 kod birimine göre keser; Dart `substring` de.
  return name.length > filterNameMaxLength
      ? '${name.substring(0, filterNameMaxLength - 1)}…'
      : name;
}

// ── Kaydetmeden önce doğrulama ───────────────────────────────────────────────

/// Düzenleyicinin ve deponun kullandığı tam doğrulama: web `FilterDefinitionSchema` + [validateFilterDefinition].
/// Alan yolları web'dekiyle aynıdır (`name`, `conditions.0.value`, `actions.1`, `actions.1.email`).
/// Klasör/etiketin HESABA ait olması çağıranın işidir.
List<FilterViolation> validateFilterForSave(
  FilterDefinition definition, {
  Set<String> ownAddresses = const {},
}) {
  final found = <FilterViolation>[];
  final name = definition.name.trim();
  if (name.length > filterNameMaxLength || hasControlCharacter(name)) {
    found.add(const FilterViolation('name', FilterViolationReason.invalid));
  }
  if (definition.conditions.isEmpty ||
      definition.conditions.length > filterMaxConditions) {
    found.add(
      const FilterViolation('conditions', FilterViolationReason.invalid),
    );
  }
  for (var i = 0; i < definition.conditions.length; i++) {
    final c = definition.conditions[i];
    if (!operatorsFor(c.field).contains(c.operator)) {
      found.add(
        FilterViolation('conditions.$i', FilterViolationReason.invalid),
      );
    } else if (c.hasValue) {
      final v = c.value.trim();
      if (v.isEmpty || v.length > filterValueMaxLength) {
        found.add(
          FilterViolation('conditions.$i.value', FilterViolationReason.invalid),
        );
      }
    }
  }
  if (definition.actions.isEmpty ||
      definition.actions.length > filterMaxActions) {
    found.add(const FilterViolation('actions', FilterViolationReason.invalid));
  }
  for (var i = 0; i < definition.actions.length; i++) {
    final a = definition.actions[i];
    if ((a.type == FilterActionType.move && (a.folderId ?? 0) <= 0) ||
        (a.type == FilterActionType.label && (a.labelId ?? 0) <= 0)) {
      found.add(FilterViolation('actions.$i', FilterViolationReason.invalid));
    }
  }
  // Şemaya takılan bir şey varsa web de kural denetimine geçmez (alan hatalarını önce düzeltin).
  if (found.any((v) => v.field.startsWith('actions.')) ||
      definition.actions.isEmpty ||
      definition.actions.length > filterMaxActions) {
    return found;
  }
  found.addAll(validateFilterDefinition(definition.actions, ownAddresses));
  return found;
}
