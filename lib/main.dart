import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/background_sync.dart';
import 'app/providers.dart';
import 'app/sync_controller.dart';
import 'data/services/app_settings.dart';
import 'data/services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Uygulama yalnızca dikey çalışır: mail listesi ve yazma ekranı
  // yatayda anlamlı bir kazanç sağlamıyor, klavye alanı daralıyor.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  final settingsStore = await AppSettingsStore.create();

  // Arka plan görevleri başlatılamasa bile uygulama açılmalı.
  try {
    await BackgroundSync.initialize();
    await BackgroundSync.schedule(settingsStore.read().syncFrequency);
  } on Object catch (error, stack) {
    debugPrint('Arka plan senkronizasyonu kurulamadı: $error\n$stack');
  }

  try {
    await NotificationService().initialize();
  } on Object catch (error) {
    debugPrint('Bildirimler kurulamadı: $error');
  }

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settingsStore),
      ],
      child: const _Bootstrap(),
    ),
  );
}

/// Eşitleme denetleyicisini uygulama ömrü boyunca canlı tutar.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap();

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  @override
  Widget build(BuildContext context) {
    // Denetleyici izlenmezse Riverpod onu oluşturmaz ve ilk eşitleme
    // hiç başlamaz.
    ref.watch(syncControllerProvider);

    // Ayarlardaki sıklık değişince arka plan görevi yeniden kaydedilir.
    ref.listen(settingsProvider, (previous, next) {
      if (previous?.syncFrequency != next.syncFrequency) {
        BackgroundSync.schedule(next.syncFrequency);
      }
    });

    return const KaydetApp();
  }
}
