import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // UIScene yasam dongusunde Flutter eklentileri `didFinishLaunching`
    // dondukten SONRA (sahne baglanirken) kaydediyor — ama BGTaskScheduler,
    // baslatma tamamlanmadan ONCE bir launch handler ister; aksi halde
    // `Workmanager().registerPeriodicTask` (bkz. background_sync.dart)
    // "No launch handler registered for task with identifier
    // kaydet.periodic.sync" hatasiyla coker. Eklentinin kendi `application`
    // geri cagirmasi bunun icin cok gec kaliyor, bu yuzden elle yapilir
    // (bkz. workmanager paketinin ornek projesindeki AppDelegate.swift).
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      // Arka plan gorevi calisirken diger eklentilerin (secure storage,
      // yerel bildirimler — bkz. background_sync.dart -> runBackgroundSync)
      // erisilebilir olmasi icin.
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Kimlik, `background_sync.dart`daki `BackgroundSync.uniqueName` ile
    // birebir ayni olmali. `earliestBeginInSeconds` yalnizca iOS'a bir ipucu
    // (alt sinir, garanti degil); gercek araligi kullanici ayarina gore Dart
    // tarafi belirler (bkz. o dosyadaki `schedule`) — burada izin verilen en
    // sik deger (15 dk) kullanilir.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "kaydet.periodic.sync",
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
