import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var notificationChannel: FlutterMethodChannel?
  private var shareChannel: ShareChannel?

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
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KaydetNotifications")
    let channel = FlutterMethodChannel(
      name: "tr.com.pazarlik.kaydet/notifications",
      binaryMessenger: registrar.messenger()
    )
    notificationChannel = channel

    // Share Extension'in App Group'a biraktigi paylasimlari Flutter'a acar
    // (bkz. ShareChannel.swift, lib/app/share_navigator.dart). Paylasim
    // Flutter'a itilmez; Flutter hazir olunca CEKER — bu yuzden motorun bu
    // noktada hazir olmasi gerekmez.
    shareChannel = ShareChannel(
      messenger: engineBridge.pluginRegistry.registrar(forPlugin: "KaydetShare").messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "registerForRemoteNotifications":
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(nil)
      case "setBadgeCount":
        guard
          let arguments = call.arguments as? [String: Any],
          let count = arguments["count"] as? Int
        else {
          result(FlutterError(code: "invalid_badge_count", message: "Badge count is required", details: nil))
          return
        }
        let badge = max(0, count)
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(badge) { error in
            if let error = error {
              result(FlutterError(code: "badge_update_failed", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = badge
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    notificationChannel?.invokeMethod("onApnsToken", arguments: token)
    #if DEBUG
      NSLog("APNs device token received")
    #endif
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    #if DEBUG
      NSLog("APNs registration failed: %@", error.localizedDescription)
    #endif
  }
}
