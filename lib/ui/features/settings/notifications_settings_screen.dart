import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/providers.dart';
import '../../../app/remote_push_controller.dart'
    show serverPushUnhealthyAccountsProvider;
import '../../../data/database/app_database.dart' show AccountRow;
import '../../../data/services/app_settings.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Bildirim ve senkronizasyon alt sayfası.
class NotificationsSettingsScreen extends ConsumerStatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  ConsumerState<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends ConsumerState<NotificationsSettingsScreen>
    with WidgetsBindingObserver {
  /// Android'in bildirim izni/kanal durumu. Uygulamanın kendi anahtarından
  /// bağımsızdır: kullanıcı sistem ayarlarından kapatmış olabilir. `null` =
  /// henüz okunmadı.
  bool? _systemEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshSystemState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Kullanıcı sistem ayarlarından dönünce durum yeniden okunur.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshSystemState();
  }

  Future<void> _refreshSystemState() async {
    try {
      final enabled = await ref.read(notificationServiceProvider).areEnabled();
      if (mounted) setState(() => _systemEnabled = enabled);
    } on Object catch (_) {
      // Durum okunamadıysa uyarı gösterilmez; anahtar yine çalışır.
    }
  }

  Future<void> _setNotifications(bool value) async {
    await ref.read(settingsProvider.notifier).setNotifications(value);
    await _refreshSystemState();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final isPush = settings.syncFrequency == SyncFrequency.push;
    final unhealthyIds = ref.watch(serverPushUnhealthyAccountsProvider);
    final unhealthyAccounts = [
      for (final account
          in ref.watch(allAccountsProvider).value ?? const <AccountRow>[])
        if (unhealthyIds.contains(account.id)) account.email,
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Bildirimler'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          const SectionHeader('BİLDİRİM VE SENKRONİZASYON'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.bell,
                title: 'Bildirimler',
                trailing: Switch(
                  value: settings.notificationsEnabled,
                  onChanged: _setNotifications,
                ),
              ),
              // İzin reddedilmişse ya da sistem ayarlarından kapatılmışsa
              // uygulamanın anahtarı açık olsa bile hiçbir bildirim düşmez;
              // sebebi ve çözümü açıkça gösterilir.
              if (_systemEnabled == false)
                SettingsTile(
                  icon: LucideIcons.bellOff,
                  title: Platform.isIOS
                      ? 'Bildirimler iOS ayarlarında kapalı'
                      : 'Bildirimler Android ayarlarında kapalı',
                  subtitle:
                      'Yeni ileti bildirimi alabilmek için telefonun '
                      'ayarlarından Kaydet bildirimlerine izin verin.',
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => ref
                      .read(notificationServiceProvider)
                      .openSystemSettings(),
                ),
              // Sunucu bu hesapların posta kutusunu izleyemiyor (kimlik bilgisi
              // reddedildi ya da posta sunucusuna ulaşılamıyor): anlık bildirim
              // bu hesaplar için çalışmaz. Sessizce bildirimsiz kalmasınlar diye
              // hangi hesapların etkilendiği gösterilir.
              if (settings.notificationsEnabled && unhealthyAccounts.isNotEmpty)
                SettingsTile(
                  icon: LucideIcons.triangleAlert,
                  title: unhealthyAccounts.length == 1
                      ? 'Bir hesabın bildirimi kurulamadı'
                      : '${unhealthyAccounts.length} hesabın bildirimi kurulamadı',
                  subtitle:
                      '${unhealthyAccounts.join(', ')}\n'
                      'Posta sunucusu bu hesabın kimlik bilgisini kabul etmiyor '
                      'ya da ulaşılamıyor. Şifre değiştiyse hesap ayarlarından '
                      'güncelleyin; bildirimler düzelince kendiliğinden başlar.',
                ),
              MenuAnchor(
                animated: true,
                menuChildren: [
                  for (final frequency in SyncFrequency.values)
                    RadioMenuButton<SyncFrequency>(
                      value: frequency,
                      groupValue: settings.syncFrequency,
                      onChanged: (value) {
                        if (value != null) {
                          ref
                              .read(settingsProvider.notifier)
                              .setSyncFrequency(value);
                        }
                      },
                      child: Text(frequency.label),
                    ),
                ],
                builder: (context, controller, child) => SettingsTile(
                  icon: LucideIcons.clock,
                  title: 'Kontrol sıklığı',
                  subtitle: settings.syncFrequency.label,
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
              // "Pil optimizasyonundan hariç tutma" yalnızca Android'de
              // (Doze) var olan bir kavramdır; iOS'ta kullanıcıya gösterecek
              // karşılığı yoktur.
              if (Platform.isAndroid)
                SettingsTile(
                  icon: LucideIcons.batteryCharging,
                  title: 'Pil optimizasyonu',
                  subtitle: isPush
                      ? 'Anlık bildirimin telefon uykudayken de kesilmemesi '
                            'için Kaydet\'i pil optimizasyonundan hariç tutun.'
                      : 'Bazı telefonlar arka plan senkronizasyonunu '
                            'kısıtlayıp bildirimleri geciktirebilir. '
                            'Kaydet\'i hariç tutmak bunu azaltır.',
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => _requestIgnoreBatteryOptimizations(context),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Android'in standart "pil optimizasyonundan hariç tut" sistem dialogunu
  /// açar. OEM'lerin kendi (MIUI/EMUI gibi) katmanlarını etkilemez, yalnızca
  /// stok Android Doze'u gevşetir — bkz. yukarıdaki açıklama metni.
  Future<void> _requestIgnoreBatteryOptimizations(BuildContext context) async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (!context.mounted) return;
    KaydetNotice.show(
      Overlay.of(context, rootOverlay: true),
      message: status.isGranted
          ? 'Kaydet pil optimizasyonundan hariç tutuldu.'
          : 'İzin verilmedi. Telefonun pil ayarlarından elle açabilirsiniz.',
    );
  }
}
