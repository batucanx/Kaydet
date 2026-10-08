import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var shareChannel: ShareChannel?
  private var notificationChannel: FlutterMethodChannel?

  /// `didRegisterForRemoteNotificationsWithDeviceToken` motor hazır olmadan
  /// (ör. soğuk başlangıçta) önce tetiklenebilir; `notificationChannel` o an
  /// hâlâ `nil` olabilir. Token burada saklanır, kanal kurulunca iletilir.
  private var pendingApnsToken: String?

  /// Dokunulan uzak bildirimin `accountId`/`uid` bilgisi; Dart çekene kadar
  /// (bkz. `takePendingMailOpen`) saklanır.
  private var pendingMailOpen: [String: Any]?

  /// Arka plan push'uyla (bkz. `didReceiveRemoteNotification`) tetiklenen
  /// headless motorlar — güçlü referans tutulmazsa ARC senkron bitmeden
  /// serbest bırakır.
  private var backgroundSyncEngines: [ObjectIdentifier: FlutterEngine] = [:]

  private static let backgroundSyncChannelName = "tr.com.pazarlik.kaydet/push_background"
  /// iOS'un arka plan push bütçesi ~30 sn; aşılırsa gelecekteki push'lar için
  /// bütçe kısıtlanır, bu yüzden erken pes edilir.
  private static let backgroundSyncTimeout: TimeInterval = 25

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

    // Uzak bildirim (APNs) cihaz token'ı ister; bildirim ALERT izninden
    // BAĞIMSIZDIR (kullanıcı henüz izin vermese de sessiz/arka plan push
    // için token alınabilir) — bu yüzden Dart tarafının tetiklemesini
    // beklemeden koşulsuz, başlangıçta çağrılır (bkz. push_backend_client.dart
    // / remote_push_sync.dart: token olmadan hiçbir hesap sunucuya kaydolmaz).
    application.registerForRemoteNotifications()

    // Bildirim merkezinin delegesi AÇIKÇA atanmalı (flutter_local_notifications
    // README'si de ister) ve başlatma tamamlanmadan ÖNCE: aksi halde aşağıdaki
    // `willPresent`/`didReceive` hiç çağrılmaz — ön plandaki push'ta liste
    // tetiklenmez, bildirime dokunmak iletiyi değil yalnızca uygulamayı açar.
    // Soğuk başlangıçta dokunuş yanıtı da ancak delege bu noktada kuruluysa
    // teslim edilir.
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // `registrar(forPlugin:)` bu Flutter surumunde optional dondurur.
    guard
      let notificationsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "KaydetNotifications"),
      let shareRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "KaydetShare")
    else { return }
    let channel = FlutterMethodChannel(
      name: "tr.com.pazarlik.kaydet/notifications",
      binaryMessenger: notificationsRegistrar.messenger()
    )
    notificationChannel = channel

    // Share Extension'in App Group'a biraktigi paylasimlari Flutter'a acar
    // (bkz. ShareChannel.swift, lib/app/share_navigator.dart). Paylasim
    // Flutter'a itilmez; Flutter hazir olunca CEKER — bu yuzden motorun bu
    // noktada hazir olmasi gerekmez.
    shareChannel = ShareChannel(messenger: shareRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePendingMailOpen":
        result(self?.pendingMailOpen)
        self?.pendingMailOpen = nil
      case "takePushStubs":
        // Notification Service Extension'ın yazdığı ileti özetleri (bkz.
        // Shared/PushStubStore.swift). Silinmez: Dart, gerçek ileti eşitlemeyle
        // gelince `removePushStubs` ile kaldırır.
        guard let root = PushStubStore.rootURL() else {
          result([])
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let stubs = PushStubStore.readAll(root: root).map { stub -> [String: Any] in
            [
              "accountId": stub.accountId,
              "uid": stub.uid,
              "from": stub.from,
              "subject": stub.subject,
              "dateMs": stub.dateMs,
            ]
          }
          DispatchQueue.main.async { result(stubs) }
        }
      case "removePushStubs":
        guard
          let arguments = call.arguments as? [String: Any],
          let accountId = arguments["accountId"] as? Int,
          let uids = arguments["uids"] as? [Int],
          let root = PushStubStore.rootURL()
        else {
          result(nil)
          return
        }
        DispatchQueue.global(qos: .utility).async {
          PushStubStore.remove(accountId: accountId, uids: uids, root: root)
          DispatchQueue.main.async { result(nil) }
        }
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

    // Motor, token geldikten SONRA hazır olduysa (olağan sıra: token bir ağ
    // gidiş-dönüşü gerektirir, motor kurulumu senkrondur) bekleyen token'ı
    // şimdi ilet.
    if let token = pendingApnsToken {
      channel.invokeMethod("onApnsToken", arguments: token)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pendingApnsToken = token
    notificationChannel?.invokeMethod("onApnsToken", arguments: token)
    // Kasıtlı olarak `#if DEBUG` DEĞİL: Release/TestFlight/ad-hoc derlemede
    // kayıt başarısız olursa bunu görmenin tek yolu Console.app'teki bu
    // günlük — token'ın kendisi yazılmaz.
    NSLog("APNs device token received")
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    NSLog("APNs registration failed: %@", error.localizedDescription)
  }

  /// Push backend'in gönderdiği `content-available` push'u burayı tetikler
  /// (bkz. backend/src/apns.ts `buildMailPayload`). Uygulama arka planda
  /// canlıysa ya da sistem tarafından (KULLANICI DEĞİL) sonlandırılmışsa
  /// çalışır; kullanıcı uygulamayı son kullanılanlardan kaydırıp kapattıysa
  /// iOS bunu hiç tetiklemez — bu Apple'ın belgelenmiş kısıtlaması, uygulama
  /// kodunun aşabileceği bir şey değil (bkz. background_sync.dart dosya başı
  /// açıklaması).
  ///
  /// `workmanager`ın BGTaskScheduler için zaten kurduğu headless-motor
  /// kalıbının aynısı: yeni bir `FlutterEngine` ile `pushBackgroundSync`
  /// giriş noktasını (bkz. background_sync.dart) çalıştırır; o da AYNI
  /// `runBackgroundSync()`'i yürütür — paralel bir senkron yolu YOK, yalnızca
  /// ikinci bir tetikleyici.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Uygulama ÖN PLANDAYSA ayrı bir motor/isolate açılmaz: ana isolate zaten
    // canlı. Ayrı isolate'in veritabanına yazdığını ana isolate'in Drift
    // akışları görmediği için liste yenilenene kadar yeni ileti görünmüyordu.
    // Push ana isolate'e iletilir; eşitlemeyi o yapar ve liste anında güncellenir.
    if application.applicationState == .active, let channel = notificationChannel {
      channel.invokeMethod("onRemotePush", arguments: ["accountId": userInfo["accountId"] ?? NSNull()])
      completionHandler(.newData)
      return
    }

    let engine = FlutterEngine(name: "kaydet.push-background-sync")
    engine.run(withEntrypoint: "pushBackgroundSync")
    GeneratedPluginRegistrant.register(with: engine)
    let key = ObjectIdentifier(engine)
    backgroundSyncEngines[key] = engine

    var finished = false
    let finish: (UIBackgroundFetchResult) -> Void = { [weak self] result in
      guard !finished else { return }
      finished = true
      // Son güçlü referansın düşmesiyle motor ve Dart isolate'i ARC tarafından
      // serbest bırakılır; ayrı bir "destroy" çağrısı gerekmez.
      self?.backgroundSyncEngines.removeValue(forKey: key)
      completionHandler(result)
    }

    let channel = FlutterMethodChannel(
      name: AppDelegate.backgroundSyncChannelName,
      binaryMessenger: engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "syncComplete" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let success = (call.arguments as? [String: Any])?["success"] as? Bool ?? false
      NSLog("Push background sync finished: %@", success ? "success" : "failed")
      result(nil)
      finish(success ? .newData : .failed)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.backgroundSyncTimeout) {
      NSLog("Push background sync timed out")
      finish(.failed)
    }
  }

  /// Ön planda gelen uzak bildirimleri (APNs) ana motora `onRemotePush` olarak iletir.
  /// iOS, ön planda gelen alert içerikli bildirimlerde `didReceiveRemoteNotification`
  /// yerine `UNUserNotificationCenterDelegate.willPresent`'i çağırır.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let request = notification.request
    // Yerel bildirimleri (flutter_local_notifications) eklenti yönetir.
    guard request.trigger is UNPushNotificationTrigger else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    let userInfo = request.content.userInfo
    notificationChannel?.invokeMethod(
      "onRemotePush",
      arguments: ["accountId": userInfo["accountId"] ?? NSNull()]
    )
    // Eklenti yerel olmayan bildirimde tamamlayıcıyı çağırmaz; çağrılmazsa
    // iOS ön planda bildirimi hiç göstermez. Burada çağrılır.
    completionHandler([.banner, .list, .sound, .badge])
  }

  /// Kullanıcı bir uzak (APNs) bildirime dokununca ilgili iletiyi açmak için
  /// hesap + IMAP uid'si saklanır. flutter_local_notifications yalnızca kendi
  /// yerel bildirimlerinin yükünü tanır; APNs bildirimlerinde yük boştur.
  ///
  /// Dart tarafı ÇEKER (`takePendingMailOpen`): soğuk başlangıçta kanal
  /// işleyicisi henüz kurulu olmayabilir. Uygulama canlıysa ayrıca
  /// `onMailTap` ile uyarılır.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let request = response.notification.request
    // Yerel bildirimleri (flutter_local_notifications) eklenti yönetir.
    guard request.trigger is UNPushNotificationTrigger else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let uid = (request.content.userInfo["uid"] as? NSNumber)?.intValue
    {
      let accountId = (request.content.userInfo["accountId"] as? NSNumber)?.intValue
      pendingMailOpen = ["accountId": accountId ?? NSNull(), "uid": uid]
      notificationChannel?.invokeMethod("onMailTap", arguments: nil)
    }
    // Eklenti yerel olmayan bildirimde tamamlayıcıyı çağırmaz; burada çağrılır.
    completionHandler()
  }
}
