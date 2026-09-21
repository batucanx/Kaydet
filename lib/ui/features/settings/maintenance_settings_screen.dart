import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../core/date_format.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Bakım alt sayfası: elle eşitleme, önbellek temizleme, çöp kutusunu
/// boşaltma.
class MaintenanceSettingsScreen extends ConsumerWidget {
  const MaintenanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Bakım'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          const SectionHeader('BAKIM'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.refreshCw,
                title: 'Şimdi eşitle',
                subtitle: sync.lastSyncAt == null
                    ? 'Henüz eşitlenmedi'
                    : 'Son: ${formatRelative(sync.lastSyncAt!)}',
                onTap: () =>
                    ref.read(syncControllerProvider.notifier).syncAll(),
              ),
              SettingsTile(
                icon: LucideIcons.hardDrive,
                title: 'Önbelleği temizle',
                subtitle: 'İndirilen ileti içeriklerini siler, iletiler kalır',
                onTap: () => _clearCache(context, ref),
              ),
              SettingsTile(
                icon: LucideIcons.trash2,
                title: 'Çöp kutusunu boşalt',
                subtitle: 'Çöp kutusundaki tüm iletileri kalıcı olarak siler',
                isDestructive: true,
                onTap: () => _emptyTrash(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Önbelleği temizle',
      message:
          'İndirilen ileti içerikleri silinecek. İletiler kalır ve '
          'açtığınızda yeniden indirilir.',
      confirmLabel: 'Temizle',
    );
    if (confirmed != true) return;
    final removed = await ref
        .read(mailRepositoryProvider)
        .pruneCachedBodies(keep: Duration.zero);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$removed ileti içeriği temizlendi.')),
    );
  }

  Future<void> _emptyTrash(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Çöp kutusunu boşalt',
      message:
          'Çöp kutusundaki tüm iletiler sunucudan da kalıcı olarak '
          'silinecek. Bu işlem geri alınamaz.',
      confirmLabel: 'Kalıcı olarak sil',
      destructive: true,
    );
    if (confirmed != true) return;
    await ref.read(mailRepositoryProvider).emptyTrash(accountId);
  }
}
