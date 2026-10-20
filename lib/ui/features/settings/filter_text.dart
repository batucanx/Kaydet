/// Gelen e-posta filtrelerinin Türkçe metinleri: düzenleyici menüleri ve liste kartlarındaki tek satırlık özetler.
///
/// KAYNAK: web `apps/web/src/features/settings/filterText.ts` (aynı cümleler). Saf Dart: arayüz yok, kolayca sınanır.
library;

import '../../../domain/use_cases/filter_rules.dart';

/// "Alan" menüsündeki satır. İki ek dosyası koşulu iki ayrı satırdır (Gmail / Yandex gibi).
class FieldChoice {
  const FieldChoice(this.key, this.label, this.field, [this.operator]);

  final String key;
  final String label;
  final FilterField field;

  /// Yalnızca ek dosyası satırlarında (değer kutusu yoktur).
  final FilterOperator? operator;
}

const List<FieldChoice> fieldChoices = [
  FieldChoice('from', 'Kimden', FilterField.from),
  FieldChoice('to', 'Kime', FilterField.to),
  FieldChoice('cc', 'CC', FilterField.cc),
  FieldChoice('subject', 'Konu', FilterField.subject),
  FieldChoice('address', 'E-posta adresi', FilterField.address),
  FieldChoice('body', 'İçerik', FilterField.body),
  FieldChoice(
    'attachment:exists',
    'Ek dosyası var',
    FilterField.attachment,
    FilterOperator.exists,
  ),
  FieldChoice(
    'attachment:notExists',
    'Ek dosyası yok',
    FilterField.attachment,
    FilterOperator.notExists,
  ),
];

String fieldChoiceKey(FilterCondition c) => c.field == FilterField.attachment
    ? 'attachment:${c.operator.name}'
    : c.field.name;

FieldChoice fieldChoiceOf(FilterCondition c) => fieldChoices.firstWhere(
  (f) => f.key == fieldChoiceKey(c),
  orElse: () => fieldChoices.first,
);

String operatorLabel(FilterOperator op) => switch (op) {
  FilterOperator.equals => 'eşittir',
  FilterOperator.contains => 'içerir',
  FilterOperator.notContains => 'içermez',
  FilterOperator.startsWith => 'ile başlar',
  FilterOperator.endsWith => 'ile biter',
  FilterOperator.exists => 'var',
  FilterOperator.notExists => 'yok',
};

/// `Kimden içerir “fatura@example.com”` · `Ek dosyası var`.
String describeCondition(FilterCondition c) {
  if (c.field == FilterField.attachment) {
    return c.operator == FilterOperator.exists
        ? 'Ek dosyası var'
        : 'Ek dosyası yok';
  }
  return '${filterFieldName(c.field)} ${operatorLabel(c.operator)} “${c.value}”';
}

/// Yeni bir koşul (menü satırına göre).
FilterCondition blankCondition(FieldChoice choice) {
  if (choice.field == FilterField.attachment) {
    return FilterCondition(
      field: FilterField.attachment,
      operator: choice.operator ?? FilterOperator.exists,
    );
  }
  return FilterCondition(
    field: choice.field,
    operator: FilterOperator.contains,
  );
}

/// Başka bir menü satırına geçer; yeni alanın da değeri varsa yazılan değer korunur.
FilterCondition changeField(FilterCondition current, FieldChoice choice) {
  final next = blankCondition(choice);
  if (!current.hasValue || !next.hasValue) return next;
  final keepOperator = operatorsFor(next.field).contains(current.operator);
  return next.copyWith(
    operator: keepOperator ? current.operator : next.operator,
    value: current.value,
  );
}

class ActionChoice {
  const ActionChoice(this.type, this.label);
  final FilterActionType type;
  final String label;
}

/// Yeni eylem menüsü. `ilet` yeni eylem olarak SUNULMAZ (web ile aynı: işlev kapalı); yalnızca daha önce kaydedilmiş bir
/// iletme eylemi düzenlenirken [forwardChoice] menüde görünür, böylece kayıt bozulmadan korunur.
const List<ActionChoice> actionChoices = [
  ActionChoice(FilterActionType.move, 'Klasöre taşı'),
  ActionChoice(FilterActionType.label, 'Etiket ekle'),
  ActionChoice(FilterActionType.spam, 'Spam olarak işaretle'),
  ActionChoice(FilterActionType.trash, 'Çöp kutusuna taşı'),
  ActionChoice(FilterActionType.archive, 'Arşivle'),
  ActionChoice(FilterActionType.delete, 'Kalıcı olarak sil'),
];

const ActionChoice forwardChoice = ActionChoice(
  FilterActionType.forward,
  'Başka e-posta adresine ilet',
);

/// Bir eylemin başvurduğu kimlikleri adlara çevirir.
class ActionNames {
  const ActionNames({required this.folder, required this.label});

  /// Klasör satır no → görünen ad (yoksa `null`).
  final String? Function(int folderId) folder;

  /// Etiket satır no → ad (yoksa `null`).
  final String? Function(int labelId) label;
}

/// `Faturalar klasörüne taşı` · `muhasebe@example.com adresine ilet` · `Arşivle`.
String describeAction(FilterAction a, ActionNames names) {
  switch (a.type) {
    case FilterActionType.move:
      final folder = names.folder(a.folderId ?? 0);
      return folder == null
          ? 'Klasöre taşı (klasör silinmiş)'
          : '$folder klasörüne taşı';
    case FilterActionType.forward:
      return '${a.email} adresine ilet';
    case FilterActionType.label:
      final label = names.label(a.labelId ?? 0);
      return label == null
          ? 'Etiket ekle (etiket silinmiş)'
          : '“$label” etiketini ekle';
    case FilterActionType.spam:
      return 'Spam olarak işaretle';
    case FilterActionType.trash:
      return 'Çöp kutusuna taşı';
    case FilterActionType.archive:
      return 'Arşivle';
    case FilterActionType.delete:
      return 'Kalıcı olarak sil';
  }
}

String matchModeHeading(FilterMatchMode mode, int conditionCount) {
  if (conditionCount <= 1) return 'Koşul';
  return mode == FilterMatchMode.all
      ? 'Koşullar (tümü)'
      : 'Koşullar (herhangi biri)';
}

/// Editörde yanlış alanın neden yanlış olduğu, kelimelerle (web `violationText` ile aynı).
String violationText(FilterViolation v) {
  switch (v.reason) {
    case FilterViolationReason.conflict:
      return v.field.startsWith('actions')
          ? 'Bu işlem diğer işlemlerle birlikte uygulanamaz.'
          : 'Bu koşul diğerleriyle çelişiyor.';
    case FilterViolationReason.duplicate:
      return 'Bu işlem zaten eklenmiş.';
    case FilterViolationReason.tooMany:
      return 'Bir filtre yalnızca tek bir adrese iletebilir.';
    case FilterViolationReason.invalid:
      if (v.field.endsWith('.email')) {
        return 'Geçerli ve kendi adresinizden farklı bir e-posta adresi girin.';
      }
      if (v.field == 'name') {
        return 'Ad en çok $filterNameMaxLength karakter olabilir ve tek satır olmalıdır.';
      }
      return 'Geçerli bir değer girin.';
  }
}
