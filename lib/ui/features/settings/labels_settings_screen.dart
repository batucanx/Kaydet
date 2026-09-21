import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Etiketler alt sayfası: etiket listesi ve oluşturma.
class LabelsSettingsScreen extends ConsumerWidget {
  const LabelsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          SectionHeader(
            'ETİKETLER',
            trailing: IconButton(
              icon: const Icon(LucideIcons.plus, size: IconSize.md),
              tooltip: 'Etiket ekle',
              onPressed: () => _createLabel(context, ref),
            ),
          ),
          SettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: labels.isEmpty
                    ? Text(
                        'Henüz etiket yok.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
                      )
                    : Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        children: [
                          for (final label in labels)
                            LabelChip(
                              name: label.name,
                              toneIndex: label.toneIndex,
                              onDeleted: () => ref
                                  .read(accountRepositoryProvider)
                                  .deleteLabel(label.id),
                            ),
                        ],
                      ),
              ),
              if (account?.supportsKeywords == false)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    0,
                    Space.lg,
                    Space.lg,
                  ),
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
        ],
      ),
    );
  }

  Future<void> _createLabel(BuildContext context, WidgetRef ref) async {
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
