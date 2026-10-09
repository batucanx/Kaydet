import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Etiketler alt sayfası: etiket listesi, oluşturma, yeniden adlandırma, silme.
class LabelsSettingsScreen extends ConsumerStatefulWidget {
  const LabelsSettingsScreen({super.key});

  @override
  ConsumerState<LabelsSettingsScreen> createState() =>
      _LabelsSettingsScreenState();
}

class _LabelsSettingsScreenState extends ConsumerState<LabelsSettingsScreen> {
  /// Sunucuyla işlem yapılan etiketler: aynı etikete art arda istek gitmesin.
  final Set<int> _busy = {};

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final account = ref.watch(activeAccountProvider).value;
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Etiketler'),
        actions: [
          IconButton(
            icon: Icon(
              LucideIcons.plus,
              size: IconSize.md,
              color: t.onAccentFill,
            ),
            tooltip: 'Etiket ekle',
            style: IconButton.styleFrom(
              backgroundColor: t.onAccentFill.withValues(alpha: 0.16),
            ),
            onPressed: () => _createLabel(context),
          ),
          const SizedBox(width: Space.md),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          SectionHeader(
            'ETİKETLER',
            trailing: Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: Text(
                '${labels.length} aktif etiket',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
              ),
            ),
          ),
          SettingsGroup(
            children: [
              if (labels.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text(
                    'Henüz etiket yok.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
                  ),
                ),
              for (final label in labels)
                _LabelRowTile(
                  key: ValueKey(label.id),
                  name: label.name,
                  toneIndex: label.toneIndex,
                  busy: _busy.contains(label.id),
                  onEdit: () => _renameLabel(context, label),
                  onDelete: () => _deleteLabel(context, label),
                ),
              InkWell(
                onTap: () => _createLabel(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg,
                    vertical: Space.md,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: t.accentSubtle,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          LucideIcons.plus,
                          size: IconSize.sm,
                          color: t.accent,
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      Text(
                        'Yeni etiket oluştur',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: t.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (account?.supportsKeywords == false)
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.info,
                        size: IconSize.sm,
                        color: t.textTertiary,
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          'Sunucunuz özel etiketleri desteklemiyor; etiketler '
                          'yalnızca bu cihazda görünür.',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: t.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (labels.isNotEmpty) ...[
            const SectionHeader('ÖNİZLEME'),
            _LabelPreviewCard(label: labels.first),
          ],
        ],
      ),
    );
  }

  Future<void> _renameLabel(BuildContext context, LabelRow label) async {
    final controller = TextEditingController(text: label.name);
    var saving = false;
    String? error;

    final renamed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> save() async {
            final name = controller.text.trim();
            if (name.isEmpty) {
              setDialogState(
                () => error = const InvalidLabelNameFailure().userMessage,
              );
              return;
            }
            if (name == label.name) {
              Navigator.of(dialogContext).pop();
              return;
            }
            setDialogState(() {
              saving = true;
              error = null;
            });
            if (mounted) setState(() => _busy.add(label.id));
            final result = await ref
                .read(accountRepositoryProvider)
                .renameLabel(labelId: label.id, newName: name);
            if (mounted) setState(() => _busy.remove(label.id));
            if (!dialogContext.mounted) return;
            switch (result) {
              case Ok():
                Navigator.of(dialogContext).pop(name);
              case Err(:final failure):
                setDialogState(() {
                  saving = false;
                  error = failure.userMessage;
                });
            }
          }

          return AlertDialog(
            title: const Text('Etiketi düzenle'),
            content: TextField(
              controller: controller,
              autofocus: true,
              enabled: !saving,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!saving) save();
              },
              decoration: InputDecoration(
                hintText: 'Etiket adı',
                errorText: error,
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              DialogActions(
                cancelLabel: 'Vazgeç',
                onCancel: () {
                  if (!saving) Navigator.of(dialogContext).pop();
                },
                confirmLabel: saving ? 'Kaydediliyor…' : 'Kaydet',
                onConfirm: () {
                  if (!saving) save();
                },
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();

    // Liste süzgeci eski adı tutuyorsa yeni ada taşı; yoksa liste boş kalır.
    if (renamed != null &&
        ref.read(messageFilterProvider).labelName == label.name) {
      ref.read(messageFilterProvider.notifier).setLabel(renamed);
    }
  }

  Future<void> _deleteLabel(BuildContext context, LabelRow label) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Etiketi sil',
      message: 'Bu etiketi silmek istediğinize emin misiniz?',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(label.id));
    final result = await ref
        .read(accountRepositoryProvider)
        .deleteLabel(label.id);
    if (!mounted) return;
    setState(() => _busy.remove(label.id));

    if (result case Err(:final failure)) {
      messenger.showSnackBar(SnackBar(content: Text(failure.userMessage)));
      return;
    }
    if (ref.read(messageFilterProvider).labelName == label.name) {
      ref.read(messageFilterProvider.notifier).setLabel(null);
    }
  }

  Future<void> _createLabel(BuildContext context) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;

    final controller = TextEditingController();
    var tone = 0;

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Yeni etiket'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Örn: Proje X'),
                ),
                const SizedBox(height: Space.lg),
                Text('Renk', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (var i = 0; i < KaydetTokens.labelToneNames.length; i++)
                      GestureDetector(
                        onTap: () => setState(() => tone = i),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: context.tokens.toneAt(i).background,
                            borderRadius: BorderRadius.circular(Radii.sm),
                            border: Border.all(
                              color: tone == i
                                  ? context.tokens.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: tone == i
                              ? Icon(
                                  LucideIcons.check,
                                  size: 16,
                                  color: context.tokens.toneAt(i).foreground,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            DialogActions(
              cancelLabel: 'Vazgeç',
              onCancel: () => Navigator.of(context).pop(false),
              confirmLabel: 'Oluştur',
              onConfirm: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;

    await ref
        .read(accountRepositoryProvider)
        .createLabel(accountId: accountId, name: name, toneIndex: tone);
  }
}

/// Etiket satırı: [renkli nokta] ad [düzenle] [sil]. Aksiyonlar her zaman
/// görünür; satırın kendisi tıklanabilir değildir.
class _LabelRowTile extends StatelessWidget {
  const _LabelRowTile({
    super.key,
    required this.name,
    required this.toneIndex,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final int toneIndex;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tone = t.toneAt(toneIndex);
    return Container(
      constraints: const BoxConstraints(minHeight: Dimens.touchTarget + 4),
      padding: const EdgeInsets.only(left: Space.lg, right: Space.xs),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: tone.foreground,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: t.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(Space.md),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              icon: Icon(
                LucideIcons.pencil,
                size: IconSize.sm,
                color: t.textSecondary,
              ),
              tooltip: 'Etiketi düzenle',
              onPressed: onEdit,
            ),
            IconButton(
              icon: Icon(
                LucideIcons.trash2,
                size: IconSize.sm,
                color: t.danger,
              ),
              tooltip: 'Etiketi sil',
              onPressed: onDelete,
            ),
          ],
        ],
      ),
    );
  }
}

/// Önizleme: etiketin bir ileti satırında nasıl görüneceği.
class _LabelPreviewCard extends StatelessWidget {
  const _LabelPreviewCard({required this.label});

  final LabelRow label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Space.lg),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: t.divider),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: t.accentSubtle,
            child: Text(
              'M',
              style: text.labelLarge?.copyWith(
                color: t.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mail Delivery System',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: t.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Örnek ileti önizlemesi',
                  style: text.labelSmall?.copyWith(color: t.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: LabelChip(name: label.name, toneIndex: label.toneIndex),
          ),
        ],
      ),
    );
  }
}
