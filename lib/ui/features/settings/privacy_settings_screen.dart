import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/providers.dart';
import '../../../app/remote_push_controller.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'data_usage_notice.dart';

/// Yayımlanmış gizlilik politikasının adresi. Mağaza (Play/App Store) bu
/// bağlantıyı zorunlu tutar; boş bırakılırsa satır gizlenir.
const String kPrivacyPolicyUrl = '';

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
                trailing: Switch(
                  value: settings.confirmBeforeDelete,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setConfirmBeforeDelete(value),
                ),
              ),
              SettingsTile(
                icon: LucideIcons.image,
                title: 'Gönderen logoları',
                subtitle:
                    'Kapalıyken gönderenlerin alan adları hiçbir dış servise '
                    'iletilmez; avatarlarda renkli baş harf görünür. Açıkken '
                    'logolar Google favicon servisinden alınır.',
                trailing: Switch(
                  value: settings.showBrandLogos,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setShowBrandLogos(value),
                ),
              ),
            ],
          ),
          const SectionHeader('VERİLERİNİZ'),
          DataUsageDetails(
            pushServerActive: ref.watch(serverPushInUseProvider),
          ),
          if (kPrivacyPolicyUrl.isNotEmpty)
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: LucideIcons.externalLink,
                  title: 'Gizlilik politikası',
                  onTap: () => _openPolicy(),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _openPolicy() async {
    try {
      await launchUrl(
        Uri.parse(kPrivacyPolicyUrl),
        mode: LaunchMode.externalApplication,
      );
    } on Object catch (_) {
      // Bağlantıyı açacak bir uygulama yok; sessizce yok sayılır.
    }
  }
}
