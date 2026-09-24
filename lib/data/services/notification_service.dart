import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../domain/use_cases/notification_text.dart';
import '../database/app_database.dart';

/// Bildirimde hangi yere dokunulduğu.
enum NotificationTapKind {
  /// Bildirimin gövdesi — iletiyi açar.
  open,

  /// "Yanıtla" eylemi — yanıt yazma ekranını açar.
  reply,
}

/// Uygulamayı öne getiren bir bildirim dokunuşu.
class NotificationTap {
  const NotificationTap(this.messageId, this.kind);

  final int messageId;
  final NotificationTapKind kind;
}

/// Yeni ileti bildirimleri.
///
/// Görünüm Outlook'u izler: başlıkta gönderen, kapalı hâlde konu, açılınca
/// konu + gövde önizlemesi, üst satırda iletinin geldiği hesap ve iletinin
/// geliş saati. Kilit ekranında içerik gizlidir (`private`).
class NotificationService {
  NotificationService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const MethodChannel _iosChannel = MethodChannel(
    'tr.com.pazarlik.kaydet/notifications',
  );
  static final StreamController<String> _apnsTokenController =
      StreamController<String>.broadcast();
  static bool _apnsHandlerInstalled = false;

  /// APNs token'ı cihazdan uygulama katmanına aktarılır. Backend kayıt
  /// endpoint'i eklenene kadar bu akış token'ı dışarı göndermez veya saklamaz.
  static Stream<String> get apnsTokens => _apnsTokenController.stream;

  static void _installApnsHandler() {
    if (_apnsHandlerInstalled) return;
    _iosChannel.setMethodCallHandler((call) async {
      if (call.method == 'onApnsToken' && call.arguments is String) {
        _apnsTokenController.add(call.arguments as String);
      }
    });
    _apnsHandlerInstalled = true;
  }

  /// iOS sistem kaydı her uygulama açılışında tazelenebilir; izin verilmemişse
  /// sessizce atlanır. Android akışına dokunmaz.
  Future<void> registerForRemoteNotifications() async {
    if (!Platform.isIOS) return;
    await initialize();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final status = await ios?.checkPermissions();
    if (status?.isEnabled != true) return;
    _installApnsHandler();
    await _iosChannel.invokeMethod<void>('registerForRemoteNotifications');
  }

  /// iOS app icon rozetini mutlak okunmamış sayıya ayarlar; artımlı değildir.
  Future<void> setAppBadgeCount(int count) async {
    if (!Platform.isIOS) return;
    try {
      await _iosChannel.invokeMethod<void>('setBadgeCount', {
        'count': count < 0 ? 0 : count,
      });
    } on PlatformException catch (_) {
      // Badge yetkisi kapalı olsa da posta kutusu ve eşitleme çalışmayı sürdürür.
    }
  }

  // `NotificationService()` her çağrıda yeni bir örnek döner (bkz.
  // `notificationServiceProvider` ve `main.dart`daki ayrı örnek) ama
  // altındaki `FlutterLocalNotificationsPlugin` tek bir singleton'dır.
  // Bu bayrak örnek yerine sınıf düzeyinde tutulmazsa ikinci bir
  // `initialize()` çağrısı (ör. `requestPermission()` içinden) eklentiyi
  // callback'siz yeniden başlatıp `main.dart`da kayıtlı dokunma/arka plan
  // işleyicilerini sessizce siler.
  //
  // NOT: statik alanlar isolate başınadır — arka plan, ön plan servisi ve
  // ana isolate her biri kendi bayrağını taşır. Başka bir isolate callback'siz
  // `initialize()` çağırsa da native taraftaki kayıtlı arka plan callback'i
  // silinmez (eklenti yalnızca null olmayan handle'ı saklar).
  static bool _initialised = false;

  static const String _channelId = 'kaydet_mail';
  static const String _channelName = 'Yeni iletiler';
  static const String _channelDescription =
      'Gelen kutusuna yeni bir ileti düştüğünde bildirir.';

  /// `res/drawable/ic_stat_kaydet.xml` — tek renkli küçük simge.
  static const String _smallIcon = 'ic_stat_kaydet';
  static const Color _accent = Color(0xFF2478C7);

  static const String _payloadPrefix = 'message:';
  static const String _groupPrefix = 'kaydet_inbox_';

  /// Bildirimdeki eylemlerin kimlikleri.
  static const String archiveActionId = 'archive';
  static const String deleteActionId = 'delete';
  static const String replyActionId = 'reply';

  /// Arşivle/Sil uygulamayı açmaz: arka plan isolate'inde sessizce işlenir
  /// (bkz. `background_sync.dart` → `notificationBackgroundHandler`).
  /// Yanıtla ise yazma ekranını açmak için uygulamayı öne getirir.
  static const List<AndroidNotificationAction> _actions = [
    AndroidNotificationAction(
      archiveActionId,
      'Arşivle',
      showsUserInterface: false,
      cancelNotification: true,
    ),
    AndroidNotificationAction(
      deleteActionId,
      'Sil',
      showsUserInterface: false,
      cancelNotification: true,
    ),
    AndroidNotificationAction(
      replyActionId,
      'Yanıtla',
      showsUserInterface: true,
      cancelNotification: true,
    ),
  ];

  /// Uygulamayı öne getiren dokunuşlar (gövde ve "Yanıtla").
  ///
  /// Yalnızca uygulama canlıyken (ön planda ya da arka planda ama
  /// sonlandırılmamış) tetiklenir — soğuk başlangıç için
  /// `appLaunchDetails()` kullanılır.
  static final StreamController<NotificationTap> _tapController =
      StreamController<NotificationTap>.broadcast();
  static Stream<NotificationTap> get taps => _tapController.stream;

  // iOS/macOS'ta "kilit ekranında gönderen/konu gizli" karşılığı yok —
  // sistem bildirimleri her zaman kilit ekranında tam gösterir.
  // `interruptionLevel` ile en azından sessiz/pasif bir sunum seçilebilirdi
  // ama bu, bildirimin hiç düşmemesi riskini taşır; varsayılan (aktif)
  // seviye bırakılır.
  static const DarwinNotificationDetails _darwinDetails =
      DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: 'kaydet_inbox',
      );

  Future<void> initialize({
    DidReceiveBackgroundNotificationResponseCallback? onBackgroundResponse,
  }) async {
    if (_initialised) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_smallIcon),
        // İzin burada istenmez — Android'deki gibi kullanıcı Ayarlar'da
        // bildirimleri açana kadar sistem izin penceresi çıkmamalı (bkz.
        // requestPermission).
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _onForegroundResponse,
      onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
    );
    _initialised = true;
  }

  /// Uygulama bir bildirime dokunularak (soğuk başlangıç) açıldıysa onu
  /// döner — `main.dart` ilk kare çizildikten sonra bunu kontrol eder.
  Future<NotificationAppLaunchDetails?> appLaunchDetails() =>
      _plugin.getNotificationAppLaunchDetails();

  // ------------------------------------------------------------------ izin

  /// Android 13+ ve iOS bildirim iznini ister.
  Future<bool> requestPermission() async {
    await initialize();
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final granted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      if (granted == true) {
        _installApnsHandler();
        await _iosChannel.invokeMethod<void>('registerForRemoteNotifications');
      }
      return granted ?? false;
    }
    if (!Platform.isAndroid) return true;
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// Bildirimler şu an sistem tarafından gösterilebilir mi? (İzin verilmemiş
  /// ya da kullanıcı sistem ayarlarından kapatmışsa `false`.)
  Future<bool> areEnabled() async {
    await initialize();
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final status = await ios?.checkPermissions();
      // `status == null` eklenti henüz sorguya cevap veremedi demektir —
      // kullanıcıyı yanlışlıkla "kapalı" göstermemek için `true` varsayılır.
      return status?.isEnabled ?? true;
    }
    if (!Platform.isAndroid) return true;
    return await _android?.areNotificationsEnabled() ?? true;
  }

  /// Uygulamanın sistem bildirim ayarları sayfasını açar — kalıcı olarak
  /// reddedilmiş izin yalnızca buradan geri açılabilir.
  Future<void> openSystemSettings() async {
    await initialize();
    await _plugin.openAppNotificationSettings();
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  // -------------------------------------------------------------- gösterim

  /// Tek bir ileti için bildirim gösterir.
  ///
  /// [accountLabel] iletinin geldiği hesabın e-postasıdır; çoklu hesapta
  /// bildirimin hangi kutuya düştüğünü gösterir.
  Future<void> showNewMail(MessageRow message, {String? accountLabel}) async {
    await initialize();
    final text = MailNotificationText.from(
      fromName: message.fromName,
      fromEmail: message.fromEmail,
      subject: message.subject,
      preview: message.preview,
    );

    // Bozuk `Date` başlığı gelecekte bir saat gösterirdi.
    final now = DateTime.now();
    final sentAt = message.dateUtc.isAfter(now) ? now : message.dateUtc;

    await _plugin.show(
      id: message.id,
      title: text.sender,
      body: text.subject,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          icon: _smallIcon,
          color: _accent,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.email,
          groupKey: _groupKeyFor(message.accountId),
          // Kilit ekranında gönderen/konu görünmez, yalnızca "yeni bildirim"
          // yazar — hassas bir konu başlığı (ör. sağlık/finans) başkasına
          // görünmesin diye.
          visibility: NotificationVisibility.private,
          styleInformation: BigTextStyleInformation(
            text.expandedBody,
            contentTitle: text.sender,
          ),
          subText: accountLabel,
          when: sentAt.millisecondsSinceEpoch,
          showWhen: true,
          // Aynı ileti için (ör. hem ön plan servisi hem periyodik görev
          // yakalarsa) ikinci gösterim tekrar ses/titreşim çıkarmaz.
          onlyAlertOnce: true,
          actions: _actions,
        ),
        iOS: _darwinDetails,
      ),
      payload: '$_payloadPrefix${message.id}',
    );
  }

  /// Hesabın bildirim grubunun özetini günceller: iki ya da daha fazla ileti
  /// bildirimi varsa özet gösterilir, aksi hâlde kaldırılır.
  ///
  /// Yeni ileti artık tek tek (gerçek zamanlı) geldiğinden sayı, gösterilen
  /// bildirimlerden okunur — bir kerede gelen toplu sayıdan değil.
  ///
  /// Yalnızca Android: bu, bildirim gölgesinde "N yeni ileti" başlıklı
  /// katlanmış grup görünümü için gerekir (`setAsGroupSummary`). iOS'ta
  /// aynı işi [_darwinDetails]'in `threadIdentifier`'ı zaten yapıyor —
  /// Bildirim Merkezi [showNewMail] ile gönderilen iletileri kendiliğinden
  /// aynı yığında toplar; ayrı bir özet bildirimi burada yalnızca
  /// yinelenen, fazladan bir uyarı olurdu.
  Future<void> refreshGroupSummary(
    int accountId, {
    String? accountLabel,
  }) async {
    if (Platform.isIOS) return;
    await initialize();
    final groupKey = _groupKeyFor(accountId);
    final summaryId = _summaryId(accountId);

    final active = await _plugin.getActiveNotifications();
    final children = [
      for (final n in active)
        if (n.groupKey == groupKey && (n.id ?? -1) >= 0) n,
    ];

    if (children.length < 2) {
      await _plugin.cancel(id: summaryId);
      return;
    }

    final count = children.length;
    await _plugin.show(
      id: summaryId,
      title: 'Kaydet',
      body: '$count yeni ileti',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          icon: _smallIcon,
          color: _accent,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.email,
          setAsGroupSummary: true,
          groupKey: groupKey,
          // Özet sessizdir; sesi/titreşimi ileti bildirimleri çıkarır.
          groupAlertBehavior: GroupAlertBehavior.children,
          onlyAlertOnce: true,
          visibility: NotificationVisibility.private,
          subText: accountLabel,
          styleInformation: InboxStyleInformation(
            [
              for (final n in children.take(6))
                '${n.title ?? ''}  ${n.body ?? ''}'.trim(),
            ],
            contentTitle: '$count yeni ileti',
            summaryText: accountLabel,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- kaldırma

  /// İletiler artık okunmuş/silinmiş/taşınmışsa bildirimlerini kaldırır.
  Future<void> cancelMessages(Iterable<int> messageIds) async {
    await initialize();
    for (final id in messageIds) {
      await _plugin.cancel(id: id);
    }
  }

  /// Şu an gösterilen ileti bildirimlerinin ileti kimlikleri.
  Future<List<int>> activeMessageIds() async {
    await initialize();
    final active = await _plugin.getActiveNotifications();
    return [
      for (final n in active)
        if ((n.groupKey ?? '').startsWith(_groupPrefix) &&
            n.id != null &&
            n.id! >= 0)
          n.id!,
    ];
  }

  // ------------------------------------------------------------- yardımcı

  static String _groupKeyFor(int accountId) => '$_groupPrefix$accountId';

  /// Pozitif ileti kimlikleriyle çakışmaması için negatif aralık kullanılır.
  static int _summaryId(int accountId) => -accountId - 1;

  static void _onForegroundResponse(NotificationResponse response) {
    final tap = tapFromResponse(response);
    if (tap != null) _tapController.add(tap);
  }

  /// Bildirim yanıtını uygulamayı açan bir dokunuşa çevirir. Arşivle/Sil gibi
  /// arka planda işlenen eylemler ve tanınmayan yükler `null` döner.
  static NotificationTap? tapFromResponse(NotificationResponse? response) {
    if (response == null) return null;
    final id = parseMessageId(response.payload);
    if (id == null) return null;
    return switch (response.actionId) {
      null || '' => NotificationTap(id, NotificationTapKind.open),
      replyActionId => NotificationTap(id, NotificationTapKind.reply),
      _ => null,
    };
  }

  /// `'message:42'` → `42`. Bozuk/bilinmeyen içerikte `null` döner.
  static int? parseMessageId(String? payload) {
    if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
    return int.tryParse(payload.substring(_payloadPrefix.length));
  }
}
