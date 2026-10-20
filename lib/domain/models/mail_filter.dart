import '../use_cases/filter_rules.dart';

/// Hesabın bir gelen e-posta filtresi, yerel kimliklerle (klasör/etiket satır no).
///
/// Salt veri: telefon filtreleri yalnızca listeler/düzenler/eşitler ve "filtreyi test et" önizlemesinde değerlendirir;
/// gelen postaya UYGULAMAZ.
class MailFilter {
  const MailFilter({
    required this.id,
    required this.accountId,
    required this.name,
    required this.enabled,
    required this.position,
    required this.matchMode,
    required this.conditions,
    required this.actions,
    required this.stopProcessing,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Belgedeki koleksiyon anahtarı.
  final String id;
  final int accountId;

  /// Boş olabilir; arayüzde [displayName] gösterilir.
  final String name;
  final bool enabled;
  final int position;
  final FilterMatchMode matchMode;
  final List<FilterCondition> conditions;
  final List<FilterAction> actions;
  final bool stopProcessing;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayName =>
      name.trim().isEmpty ? defaultFilterName(conditions) : name;

  FilterDefinition get definition => FilterDefinition(
    name: name,
    enabled: enabled,
    matchMode: matchMode,
    conditions: conditions,
    actions: actions,
    stopProcessing: stopProcessing,
  );
}
