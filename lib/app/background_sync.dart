import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../core/result.dart';
import '../data/database/app_database.dart';
import '../data/database/tables.dart';
import '../data/repositories/mail_connection.dart';
import '../data/repositories/mail_repository.dart';
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
/// sınır işletim sistemi tarafından dayatılır ve aşılamaz. Uygulama
/// önplandayken IMAP IDLE ile anlık bildirim alınır (bkz. SyncController).
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

/// Arka planda tek bir eşitleme turu.
///
/// Dönüş `false` olursa WorkManager görevi yeniden dener.
Future<bool> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();
  final secureStore = FlutterSecureStore();
  final imap = EnoughMailImapService();
  final notifications = NotificationService();
  final googleOAuth = GoogleOAuthService();

  try {
    final account = await database.activeAccount();
    if (account == null) return true;

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

    final connected = await connection.ensureConnected(account.id);
    if (connected is Err<void>) {
      // Kimlik hatası kalıcıdır; tekrar denemek işe yaramaz.
      return connected.failure is AuthFailure;
    }

    // Önce kullanıcının bekleyen eylemleri ve giden kutusu işlenir:
    // kullanıcının gönderdiği ileti, yeni ileti çekmekten daha önceliklidir.
    await repository.processQueue(account.id);

    final inbox =
        await database.mailboxBySpecialUse(account.id, SpecialUse.inbox);
    if (inbox == null) {
      await engine.syncMailboxes(account.id);
      return true;
    }

    final outcome = await engine.syncMailbox(
      accountId: account.id,
      mailbox: inbox,
    );

    if (outcome is Ok<SyncOutcome> && settings.notificationsEnabled) {
      final newIds = outcome.value.newMessageIds;
      if (newIds.isNotEmpty) {
        // Önizleme metni için gövdeleri çek, sonra bildir.
        await engine.prefetchBodies(
          accountId: account.id,
          mailbox: inbox,
          limit: newIds.length.clamp(1, 10),
        );
        final rows = await database.messagesByIds(newIds);
        final unread = rows.where((m) => !m.isSeen).toList();
        for (final row in unread.take(5)) {
          await notifications.showNewMail(row);
        }
        await notifications.showSummary(unread.length);
      }
    }

    return true;
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
