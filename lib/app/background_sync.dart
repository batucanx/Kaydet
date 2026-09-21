import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../core/result.dart';
import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../data/repositories/mail_connection.dart';
import '../data/repositories/mail_repository.dart';
import '../data/repositories/new_mail_notifier.dart';
import '../data/repositories/sync_engine.dart';
import '../data/services/app_settings.dart';
import '../data/services/google_oauth_service.dart';
import '../data/services/imap_service.dart';
import '../data/services/notification_service.dart';
import '../data/services/secure_store.dart';
import '../data/services/smtp_service.dart';

/// Arka plan senkronizasyonu.
///
/// Android'de WorkManager'ın en sık çalışma aralığı 15 dakikadır; bu alt
/// sınır işletim sistemi tarafından dayatılır ve aşılamaz. Bu görev bu yüzden
/// ANLIK bildirimin değil, yedeğinin işidir: "Anlık" modda ön plan servisi
/// (bkz. `PushService`) IMAP IDLE ile iletileri geldikleri anda yakalar;
/// servis sistem tarafından öldürülürse ya da bir bağlantı sessizce
/// koparsa kaçan iletileri bu periyodik tur toplar. Servis kapalı
/// sıklıklarda (15 dk / 30 dk / saatte bir) bildirimin tek kaynağıdır.
/// Uygulama önplandayken IDLE'ı `SyncController` yönetir.
abstract final class BackgroundSync {
  static const String taskName = 'kaydet.sync';
  static const String uniqueName = 'kaydet.periodic.sync';

  /// Uygulama açılışında çağrılır.
  static Future<void> initialize() async {
    await Workmanager().initialize(backgroundCallbackDispatcher);
  }

  /// Kullanıcının seçtiği sıklığa göre görevi kaydeder.
  static Future<void> schedule(SyncFrequency frequency) async {
    await cancel();
    if (!frequency.isBackgroundEnabled) return;

    // WorkManager 15 dakikanın altını kabul etmez.
    final interval = frequency.interval < const Duration(minutes: 15)
        ? const Duration(minutes: 15)
        : frequency.interval;

    await Workmanager().registerPeriodicTask(
      uniqueName,
      taskName,
      frequency: interval,
      initialDelay: const Duration(minutes: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  static Future<void> cancel() =>
      Workmanager().cancelByUniqueName(uniqueName);
}

/// Arka plan isolate'inin giriş noktası.
///
/// Bu fonksiyon ayrı bir isolate'te çalışır: uygulamanın bellekteki
/// durumuna erişemez, her şeyi sıfırdan kurar.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != BackgroundSync.taskName) return true;
    return runBackgroundSync();
  });
}

/// Arka planda tek bir eşitleme turu — cihazdaki TÜM hesapları sırayla
/// eşitler (bkz. `MailConnection` dosya başı açıklaması: tek bağlantı
/// hesap değiştirerek sırayla kullanılır, eşzamanlı değil).
///
/// Dönüş `false` olursa WorkManager görevi yeniden dener.
Future<bool> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();
  final secureStore = FlutterSecureStore();
  final imap = EnoughMailImapService();
  final notifier = NewMailNotifier(
    database: database,
    notifications: NotificationService(),
  );
  final googleOAuth = GoogleOAuthService();

  try {
    final accounts = await database.allAccounts();
    if (accounts.isEmpty) return true;

    final settingsStore = await AppSettingsStore.create();
    final settings = settingsStore.read();

    final connection = MailConnection(
      database: database,
      secureStore: secureStore,
      imapService: imap,
      googleOAuth: googleOAuth,
    );
    final engine = SyncEngine(database: database, connection: connection);
    final repository = MailRepository(
      database: database,
      connection: connection,
      syncEngine: engine,
      smtpService: EnoughMailSmtpService(),
    );

    // Bir hesabın geçici (ağ) hatası diğerlerini engellemez; yalnızca o
    // hesap atlanır ve göreve "yeniden dene" işareti konur.
    var shouldRetry = false;

    for (final account in accounts) {
      final connected = await connection.ensureConnected(account.id);
      if (connected is Err<void>) {
        // Kimlik hatası kalıcıdır, tekrar denemek işe yaramaz; diğer
        // hatalarda görev WorkManager tarafından yeniden denenir.
        if (connected.failure is! AuthFailure) shouldRetry = true;
        continue;
      }

      // Önce kullanıcının bekleyen eylemleri ve giden kutusu işlenir:
      // kullanıcının gönderdiği ileti, yeni ileti çekmekten daha önceliklidir.
      await repository.processQueue(account.id);

      final inbox =
          await database.mailboxBySpecialUse(account.id, SpecialUse.inbox);
      if (inbox == null) {
        await engine.syncMailboxes(account.id);
        continue;
      }

      final outcome = await engine.syncMailbox(
        accountId: account.id,
        mailbox: inbox,
      );

      if (outcome is Ok<SyncOutcome> && settings.notificationsEnabled) {
        await _notifyNewMessages(
          engine: engine,
          notifier: notifier,
          accountId: account.id,
          inbox: inbox,
          outcome: outcome.value,
        );
      }

      // `unawaited` DEĞİL: arka plan isolate'i bu fonksiyon dönünce
      // WorkManager tarafından kapatılabilir, fırlatılıp unutulan bir iş
      // tamamlanmadan kesilirdi (bkz. `SyncController`daki foreground
      // eşdeğeri — orada uygulama süreci canlı kaldığı için `unawaited`
      // güvenli, burada değil).
      await repository.trimMailbox(inbox.id);
    }

    // Başka bir cihazdan okunan/silinen iletilerin bildirimleri kalkar.
    if (settings.notificationsEnabled) await notifier.dismissHandled();

    return !shouldRetry;
  } catch (_) {
    // Arka planda çökmek görevin sürekli yeniden denenmesine yol açar;
    // hata yutulur ve bir sonraki tur beklenir.
    return true;
  } finally {
    await imap.dispose();
    googleOAuth.dispose();
    await database.close();
  }
}

Future<void> _notifyNewMessages({
  required SyncEngine engine,
  required NewMailNotifier notifier,
  required int accountId,
  required MailboxRow inbox,
  required SyncOutcome outcome,
}) async {
  if (outcome.initialDownload || outcome.newMessageIds.isEmpty) return;

  // Önizleme metni için gövdeleri çek, sonra bildir.
  await engine.prefetchBodies(
    accountId: accountId,
    mailbox: inbox,
    limit: outcome.newMessageIds.length.clamp(1, 10),
  );
  await notifier.notifyNew(accountId: accountId, outcome: outcome);
}

/// Bildirimdeki "Arşivle" / "Sil" eylemlerine dokunulunca çağrılır.
///
/// `showsUserInterface: false` olan eylemler ayrı bir arka plan izole'sinde
/// çalışır (bkz. `NotificationService._actions`); bu yüzden burası
/// `runBackgroundSync` gibi kendi veritabanı/bağlantı bağımlılıklarını
/// sıfırdan kurar, uygulamanın bellekteki durumuna erişemez. "Yanıtla"
/// uygulamayı öne getirdiği için burada değil, ana isolate'te işlenir
/// (bkz. `NotificationNavigator`).
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) {
  final messageId = NotificationService.parseMessageId(response.payload);
  if (messageId == null) return;

  switch (response.actionId) {
    case NotificationService.archiveActionId:
      unawaited(_applyMessageAction(messageId, archive: true));
    case NotificationService.deleteActionId:
      unawaited(_applyMessageAction(messageId, archive: false));
  }
}

Future<void> _applyMessageAction(
  int messageId, {
  required bool archive,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bildirim eylemi ayrı bir isolate'te çalışır; Dart tarafı eklentilerin
  // (path_provider, secure storage, shared_preferences) kaydı açıkça yapılır.
  DartPluginRegistrant.ensureInitialized();

  final database = AppDatabase();
  final secureStore = FlutterSecureStore();
  final imap = EnoughMailImapService();
  final googleOAuth = GoogleOAuthService();
  final notifications = NotificationService();

  try {
    final message = await database.messageById(messageId);
    if (message == null) return;

    final connection = MailConnection(
      database: database,
      secureStore: secureStore,
      imapService: imap,
      googleOAuth: googleOAuth,
    );
    final engine = SyncEngine(database: database, connection: connection);
    final repository = MailRepository(
      database: database,
      connection: connection,
      syncEngine: engine,
      smtpService: EnoughMailSmtpService(),
    );

    // Önce yerelde uygulanıp kalıcı işlem kuyruğuna yazılır: süreç bu noktadan
    // sonra kesilse bile işlem bir sonraki eşitlemede sunucuya gider.
    if (archive) {
      await repository.archive([messageId]);
    } else {
      await repository.deleteMessages([messageId]);
    }

    // Kuyruğun sunucuya işlenmesi beklenir; aksi hâlde aşağıdaki `finally`
    // bağlantıyı ve veritabanını turun ortasında kapatırdı.
    await repository.waitForQueue();

    // Eylem grubun çocuk sayısını değiştirdi: kalan tek bildirim için
    // özet kaldırılır.
    final account = await database.accountById(message.accountId);
    await notifications.refreshGroupSummary(
      message.accountId,
      accountLabel: account?.email,
    );
  } catch (_) {
    // Bildirim eylem işleyicisinde çökmek sessizce yutulur; işlem kuyruğa
    // yazıldıysa bir sonraki eşitlemede yine denenir.
  } finally {
    await imap.dispose();
    googleOAuth.dispose();
    await database.close();
  }
}
