import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/background_sync.dart';
import 'app/notification_navigator.dart';
import 'app/providers.dart';
import 'app/push_controller.dart';
import 'app/push_service.dart';
import 'app/remote_push_controller.dart';
import 'app/share_navigator.dart';
import 'app/sync_controller.dart';
import 'data/services/app_settings.dart';
import 'data/services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Avatarlar için indirilen marka logoları (bkz. `BrandAvatar`) burada
  // önbellekleniyor. Varsayılan (1000 görsel / 100MB) bu uygulama için
  // gereğinden büyük — sınırlamak erken tahliyeyi (ve dolayısıyla kaydırma
  // sırasında gereksiz yeniden indirmeyi) önler, belleği de gereksiz şişirmez.
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 50 << 20;

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
    await NotificationService().initialize(
      onBackgroundResponse: notificationBackgroundHandler,
    );
  } on Object catch (error) {
    debugPrint('Bildirimler kurulamadı: $error');
  }

  // Anlık bildirim servisinin seçenekleri ve servis ↔ arayüz mesaj kanalı.
  // Servisin kendisi burada başlatılmaz: `PushController` ayarlara göre
  // açar/kapatır.
  try {
    PushService.initialize();
  } on Object catch (error) {
    debugPrint('Anlık bildirim servisi kurulamadı: $error');
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
  void initState() {
    super.initState();
    // Uygulama bir bildirime dokunularak açıldıysa ilk kareden sonra aynı
    // iletiye gider — o anda henüz `Navigator` hazır olmayabilir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationNavigatorProvider).handleColdStart();
      // Uygulama sistem "Paylaş" menüsünden açıldıysa dosyalar ekli Yeni İleti
      // açılır (bkz. `ShareNavigator`).
      ref.read(shareNavigatorProvider).handleColdStart();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Denetleyici izlenmezse Riverpod onu oluşturmaz ve ilk eşitleme
    // hiç başlamaz.
    ref.watch(syncControllerProvider);

    // Bildirim dokunuşlarını dinlemeye başlar (bkz.
    // `NotificationNavigator`); izlenmezse Riverpod onu hiç oluşturmaz.
    ref.watch(notificationNavigatorProvider);

    // Sistem "Paylaş" menüsünden gelen dosyaları dinler (bkz.
    // `ShareNavigator`); izlenmezse Riverpod onu hiç oluşturmaz.
    ref.watch(shareNavigatorProvider);

    // Anlık bildirim servisini ayarlara göre açıp kapatır ve servisle
    // konuşur (bkz. `PushController`); izlenmezse hiç oluşturulmaz.
    ref.watch(pushControllerProvider);

    // iOS'ta hesapları push sunucusuna kaydeder (bkz. `RemotePushController`);
    // yapılandırma ya da kullanıcı onayı yoksa hiçbir şey yapmaz.
    ref.watch(remotePushControllerProvider);

    // Ayarlardaki sıklık değişince arka plan görevi yeniden kaydedilir.
    ref.listen(settingsProvider, (previous, next) {
      if (previous?.syncFrequency != next.syncFrequency) {
        BackgroundSync.schedule(next.syncFrequency);
      }
    });

    return const KaydetApp();
  }
}
