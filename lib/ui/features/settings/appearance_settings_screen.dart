import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/services/app_settings.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Görünüm alt sayfası: tema seçimi.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

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
        title: const Text('Görünüm'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          const SectionHeader('GÖRÜNÜM'),
          SettingsGroup(
            children: [
              MenuAnchor(
                animated: true,
                menuChildren: [
                  for (final mode in AppThemeMode.values)
                    RadioMenuButton<AppThemeMode>(
                      value: mode,
                      groupValue: settings.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(value);
                        }
                      },
                      child: Text(mode.label),
                    ),
                ],
                builder: (context, controller, child) => SettingsTile(
                  icon: LucideIcons.palette,
                  title: 'Tema',
                  subtitle: settings.themeMode.label,
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
