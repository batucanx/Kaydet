import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'accounts_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'labels_settings_screen.dart';
import 'maintenance_settings_screen.dart';
import 'notifications_settings_screen.dart';
import 'privacy_settings_screen.dart';
import 'signatures_settings_screen.dart';

/// Ayarlar ekranı: kategorilere göre gruplanmış (Grouped List), her satır
/// kendi alt sayfasına açılan hiyerarşik bir yapı (Drill-down navigation).
///
/// Bu ekran yalnızca bir kategorinin GÜNCEL DURUMUNU özetler (alt başlık) —
/// hiçbir eylem burada değil, hepsi ilgili alt sayfada gerçekleşir. Bir
/// kategoriye dokunmak `context.pushScreen` ile o alt sayfayı açar (bkz.
/// `KaydetRoute` — tüm ekran geçişlerinin tek noktası).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final settings = ref.watch(settingsProvider);
    final account = ref.watch(activeAccountProvider).value;
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    final signatures =
        ref.watch(signaturesProvider).value ?? const <SignatureRow>[];
    final sync = ref.watch(syncControllerProvider);

    final themeLabel = settings.themeMode.label;

    return Scaffold(
      appBar: AppBar(
        // Bu ekranın kendi `Scaffold`u `AppShell`'in klasör/modül menüsünü
        // taşımaz; menü butonu Flutter'ın otomatik `leading`iyle gelmez,
        // elle eklenir (bkz. `mail_list_screen.dart`daki aynı desen).
        leading: IconButton(
          icon: const Icon(LucideIcons.menu),
          tooltip: 'Menü',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: const Text('Ayarlar'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          const SectionHeader('HESAP'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.users,
                title: 'Hesaplar',
                subtitle: account?.email ?? 'Hesap eklenmedi',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    context.pushScreen(const AccountsSettingsScreen()),
              ),
            ],
          ),

          const SectionHeader('GENEL'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.palette,
                title: 'Görünüm',
                subtitle: themeLabel,
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    context.pushScreen(const AppearanceSettingsScreen()),
              ),
              SettingsTile(
                icon: LucideIcons.bell,
                title: 'Bildirimler',
                subtitle: settings.notificationsEnabled
                    ? settings.syncFrequency.label
                    : 'Kapalı',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    context.pushScreen(const NotificationsSettingsScreen()),
              ),
              SettingsTile(
                icon: LucideIcons.shieldAlert,
                title: 'Gizlilik',
                subtitle: settings.confirmBeforeDelete
                    ? 'Silmeden önce sor açık'
                    : 'Silmeden önce sor kapalı',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () => context.pushScreen(const PrivacySettingsScreen()),
              ),
              SettingsTile(
                icon: LucideIcons.tag,
                title: 'Etiketler',
                subtitle: labels.isEmpty
                    ? 'Henüz etiket yok'
                    : '${labels.length} etiket',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () => context.pushScreen(const LabelsSettingsScreen()),
              ),
              SettingsTile(
                icon: LucideIcons.penLine,
                title: 'İmzalar',
                subtitle: signatures.isEmpty
                    ? 'Henüz imza yok'
                    : '${signatures.length} imza',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    context.pushScreen(const SignaturesSettingsScreen()),
              ),
              SettingsTile(
                icon: LucideIcons.hardDrive,
                title: 'Bakım',
                subtitle: sync.lastSyncAt == null
                    ? 'Henüz eşitlenmedi'
                    : 'Son: ${formatRelative(sync.lastSyncAt!)}',
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    context.pushScreen(const MaintenanceSettingsScreen()),
              ),
            ],
          ),

          const SizedBox(height: Space.xl),
          Center(
            child: Text(
              'Kaydet 1.0.0',
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
