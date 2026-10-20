import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/filter_providers.dart';
import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_filter.dart';
import '../../../domain/use_cases/filter_record.dart' show folderSegments;
import '../../../domain/use_cases/filter_rules.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'filter_editor_screen.dart';
import 'filter_text.dart';

/// Klasörün listelerde görünen adı: `INBOX.Faturalar` → `Faturalar`, `INBOX.A.B` → `A / B`.
String filterFolderLabel(MailboxRow box) {
  var parts = folderSegments(box.path, box.delimiter);
  if (parts.length > 1 && parts.first.toUpperCase() == 'INBOX') {
    parts = parts.sublist(1);
  }
  final joined = parts.join(' / ');
  return joined.isEmpty ? box.name : joined;
}

/// Ayarlar > Filtreler: gelen e-posta filtrelerinin listesi, sıralaması, açıp kapatılması, silinmesi ve düzenleyiciye girişi.
///
/// Filtreler web ve diğer cihazlarla ayar belgesi üzerinden eşitlenir. Bu uygulama filtreleri gelen postaya UYGULAMAZ:
/// yalnızca listeler, düzenler ve "filtreyi test et" ile bir iletide dener.
class FiltersSettingsScreen extends ConsumerStatefulWidget {
  const FiltersSettingsScreen({super.key});

  @override
  ConsumerState<FiltersSettingsScreen> createState() =>
      _FiltersSettingsScreenState();
}

class _FiltersSettingsScreenState extends ConsumerState<FiltersSettingsScreen> {
  /// Üzerinde işlem yapılan filtreler: art arda dokunuşlar çakışmasın.
  final Set<String> _busy = {};

  void _notice(String message) {
    if (!mounted) return;
    KaydetNotice.show(Overlay.of(context), message: message);
  }

  Future<void> _edit(MailFilter? filter) =>
      context.pushScreen(FilterEditorScreen(initial: filter));

  Future<void> _toggle(MailFilter filter) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null || !_busy.add(filter.id)) return;
    setState(() {});
    try {
      final next = !filter.enabled;
      await ref
          .read(mailFilterRepositoryProvider)
          .setEnabled(accountId, filter.id, next);
      _notice(
        next
            ? '“${filter.displayName}” etkinleştirildi.'
            : '“${filter.displayName}” devre dışı bırakıldı.',
      );
    } finally {
      _busy.remove(filter.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _move(List<MailFilter> all, MailFilter filter, int delta) async {
    final accountId = ref.read(accountIdProvider);
    final at = all.indexWhere((f) => f.id == filter.id);
    final to = at + delta;
    if (accountId == null || at < 0 || to < 0 || to >= all.length) return;
    if (!_busy.add(filter.id)) return;
    setState(() {});
    try {
      final order = [for (final f in all) f.id];
      final moved = order.removeAt(at);
      order.insert(to, moved);
      await ref.read(mailFilterRepositoryProvider).reorder(accountId, order);
    } finally {
      _busy.remove(filter.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(MailFilter filter) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Filtre silinsin mi?',
      message:
          '“${filter.displayName}” silinecek. Bu işlem geri alınamaz. '
          'Filtrenin daha önce taşıdığı e-postalar yerinde kalır.',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(mailFilterRepositoryProvider).delete(accountId, filter.id);
    _notice('“${filter.displayName}” silindi.');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final filters = ref.watch(mailFiltersProvider);
    final mailboxes = ref.watch(mailboxesProvider).value ?? const [];
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    final names = ActionNames(
      folder: (id) {
        for (final box in mailboxes) {
          if (box.id == id) return filterFolderLabel(box);
        }
        return null;
      },
      label: (id) {
        for (final l in labels) {
          if (l.id == id) return l.name;
        }
        return null;
      },
    );

    final items = filters.value ?? const <MailFilter>[];
    final atLimit = items.length >= filterMaxPerAccount;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Filtreler'),
        actions: [
          if (filters.hasValue && items.isNotEmpty)
            IconButton(
              icon: Icon(
                LucideIcons.plus,
                size: IconSize.md,
                color: t.onAccentFill,
              ),
              tooltip: atLimit
                  ? 'En fazla $filterMaxPerAccount filtre oluşturulabilir'
                  : 'Filtre oluştur',
              style: IconButton.styleFrom(
                backgroundColor: t.onAccentFill.withValues(alpha: 0.16),
              ),
              onPressed: atLimit ? null : () => _edit(null),
            ),
          const SizedBox(width: Space.md),
        ],
      ),
      body: filters.when(
        loading: () => Center(
          child: Semantics(
            label: 'Filtreler yükleniyor',
            child: const CircularProgressIndicator(),
          ),
        ),
        error: (error, _) => EmptyState(
          icon: LucideIcons.triangleAlert,
          title: 'Filtreler yüklenemedi',
          description: 'Bir sorun oluştu. Yeniden deneyin.',
          action: FilledButton(
            onPressed: () => ref.invalidate(mailFiltersProvider),
            child: const Text('Yeniden dene'),
          ),
        ),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: LucideIcons.funnel,
                title: 'Henüz oluşturulmuş bir filtre yok.',
                description:
                    'Gelen e-postalarınızı otomatik olarak düzenlemek için '
                    'ilk filtrenizi oluşturun.',
                action: FilledButton(
                  onPressed: () => _edit(null),
                  child: const Text('Filtre oluştur'),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: Space.huge),
                children: [
                  const _InfoNote(),
                  SectionHeader(
                    'FİLTRELER',
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: Text(
                        '${list.length} filtre · çalışma sırasına göre',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                      ),
                    ),
                  ),
                  for (var i = 0; i < list.length; i++)
                    _FilterCard(
                      key: ValueKey(list[i].id),
                      filter: list[i],
                      index: i,
                      count: list.length,
                      names: names,
                      busy: _busy.contains(list[i].id),
                      onEdit: () => _edit(list[i]),
                      onToggle: () => _toggle(list[i]),
                      onUp: () => _move(list, list[i], -1),
                      onDown: () => _move(list, list[i], 1),
                      onDelete: () => _delete(list[i]),
                    ),
                  if (atLimit)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        Space.sm,
                        Space.lg,
                        0,
                      ),
                      child: Text(
                        'En fazla $filterMaxPerAccount filtre oluşturulabilir.',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Telefonun filtrelerle ne yapıp ne yapmadığını söyleyen kısa not.
class _InfoNote extends StatelessWidget {
  const _InfoNote();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.lg,
        Space.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: IconSize.sm, color: t.textTertiary),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'Filtreler web ve diğer cihazlarınızla eşitlenir. Bu cihazda '
              'düzenleyebilir ve bir iletide deneyebilirsiniz; gelen '
              'e-postalara bu cihaz uygulamaz.',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterCard extends StatelessWidget {
  const _FilterCard({
    super.key,
    required this.filter,
    required this.index,
    required this.count,
    required this.names,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
    required this.onUp,
    required this.onDown,
    required this.onDelete,
  });

  final MailFilter filter;
  final int index;
  final int count;
  final ActionNames names;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final name = filter.displayName;
    final muted = filter.enabled ? t.textPrimary : t.textTertiary;
    final small = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: filter.enabled ? t.textSecondary : t.textTertiary,
    );

    return Semantics(
      container: true,
      label:
          'Filtre ${index + 1}: $name, '
          '${filter.enabled ? 'aktif' : 'devre dışı'}',
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: t.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: busy ? null : onEdit,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.sm,
                  Space.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: t.accentSubtle,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${index + 1}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: t.accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: muted,
                            ),
                          ),
                        ),
                        Semantics(
                          label: '“$name” filtresi',
                          toggled: filter.enabled,
                          child: Switch(
                            value: filter.enabled,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: busy ? null : (_) => onToggle(),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 38),
                      child: Text(
                        filter.enabled ? 'Aktif' : 'Devre dışı',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: filter.enabled ? t.success : t.textTertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Padding(
                      padding: const EdgeInsets.only(left: 38, right: Space.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            matchModeHeading(
                              filter.matchMode,
                              filter.conditions.length,
                            ),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                          for (final c in filter.conditions)
                            Text(describeCondition(c), style: small),
                          const SizedBox(height: Space.xs),
                          Text(
                            'İşlemler',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                          for (final a in filter.actions)
                            Text('→ ${describeAction(a, names)}', style: small),
                          if (filter.stopProcessing) ...[
                            const SizedBox(height: Space.xs),
                            Text(
                              'Eşleşirse sonraki filtreler çalıştırılmaz.',
                              style: small,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: t.divider),
            Row(
              children: [
                const SizedBox(width: Space.xs),
                IconButton(
                  icon: const Icon(LucideIcons.arrowUp, size: IconSize.md),
                  tooltip: '“$name” filtresini yukarı taşı',
                  onPressed: busy || index == 0 ? null : onUp,
                ),
                IconButton(
                  icon: const Icon(LucideIcons.arrowDown, size: IconSize.md),
                  tooltip: '“$name” filtresini aşağı taşı',
                  onPressed: busy || index == count - 1 ? null : onDown,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(LucideIcons.pencil, size: IconSize.sm),
                  label: const Text('Düzenle'),
                  onPressed: busy ? null : onEdit,
                ),
                IconButton(
                  icon: Icon(
                    LucideIcons.trash2,
                    size: IconSize.md,
                    color: busy ? null : t.danger,
                  ),
                  tooltip: '“$name” filtresini sil',
                  onPressed: busy ? null : onDelete,
                ),
                const SizedBox(width: Space.xs),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
