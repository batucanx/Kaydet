import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'push_task_handler.dart';

/// Anlık bildirim için Android ön plan servisinin ana isolate tarafı.
///
/// Android arka plandaki uygulamanın bağlantılarını kısa sürede kestiği için
/// (Doze, uygulama bekletme) sunucuyu sürekli dinlemenin tek güvenilir yolu,
/// durum çubuğunda kalıcı bir bildirimi olan bir ön plan servisidir. Servis
/// içinde `PushTaskHandler` her hesabın Gelen Kutusu'nu IMAP IDLE ile dinler;
/// yeni ileti geldiği anda bildirim düşer (WorkManager'ın 15 dakikalık alt
/// sınırı yoktur).
///
/// Bu sınıf yalnızca servisi açıp kapatır ve mesajlaşır; asıl iş
/// `push_task_handler.dart`ta.
abstract final class PushService {
  static const int _serviceId = 4210;

  /// Kalıcı bildirimin simgesi — `AndroidManifest.xml`deki `<meta-data>`
  /// adıyla birebir aynı olmalı.
  static const String _iconMetaData = 'tr.com.pazarlik.kaydet.push_icon';

  /// `main()` içinde, `runApp`ten önce bir kez çağrılır.
  static void initialize() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'kaydet_push',
        channelName: 'Arka plan bağlantısı',
        channelDescription:
            'Yeni iletileri geldikleri anda alabilmek için Kaydet\'in arka '
            'planda çalıştığını gösterir.',
        // Sessiz ve düşük öncelikli: durum çubuğunda yer kaplamaz, ses
        // çıkarmaz. Yeni ileti bildirimleri ayrı, yüksek öncelikli kanaldadır.
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        visibility: NotificationVisibility.VISIBILITY_SECRET,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Olay tabanlı çalışır; periyodik tetikleyici gerekmez.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        // Kilitli ekranda CPU uyusa IDLE soketine gelen veri işlenemez ve
        // bildirim ekran açılana kadar gecikir.
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        // Uygulama son kullanılanlardan kaydırılıp kapatılsa da servis
        // (ve dolayısıyla bildirimler) sürer.
        stopWithTask: false,
      ),
    );
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Servisi başlatır. Android 12+ yalnızca uygulama öndeyken başlatmaya izin
  /// verir; arka plandan çağrılırsa `false` döner.
  static Future<bool> start() async {
    if (await isRunning) return true;
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      notificationTitle: 'Kaydet',
      notificationText: 'E-posta bağlantısı etkin',
      notificationIcon: const NotificationIcon(metaDataName: _iconMetaData),
      callback: pushServiceEntry,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    if (!await isRunning) return;
    await FlutterForegroundTask.stopService();
  }

  /// Servise mesaj gönderir. Servis çalışmıyorsa sessizce yok sayılır.
  static Future<void> send(Map<String, Object?> message) async {
    try {
      if (!await isRunning) return;
      FlutterForegroundTask.sendDataToTask(message);
    } on Object catch (_) {
      // Servis tam bu sırada kapanmış olabilir.
    }
  }

  static void addListener(DataCallback callback) =>
      FlutterForegroundTask.addTaskDataCallback(callback);

  static void removeListener(DataCallback callback) =>
      FlutterForegroundTask.removeTaskDataCallback(callback);
}

/// Servisin giriş noktası. Servis kendi isolate'inde bunu çağırır; bu yüzden
/// üst düzey ve `entry-point` olarak işaretli olmak zorundadır.
@pragma('vm:entry-point')
void pushServiceEntry() {
  FlutterForegroundTask.setTaskHandler(PushTaskHandler());
}
