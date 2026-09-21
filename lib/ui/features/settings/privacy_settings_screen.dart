import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Gizlilik alt sayfası.
class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Gizlilik'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          const SectionHeader('GİZLİLİK'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.trash2,
                title: 'Silmeden önce sor',
                subtitle: 'Kalıcı silme işlemlerinde onay iste',
                trailing: Switch(
                  value: settings.confirmBeforeDelete,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setConfirmBeforeDelete(value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
