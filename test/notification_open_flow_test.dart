@Timeout(Duration(seconds: 90))
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/notification_intent.dart';
import 'package:kaydet/app/notification_navigator.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/sync_controller.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/dedicated_target_fetcher.dart';
import 'package:kaydet/data/repositories/notification_target_resolver.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/notification_service.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/features/mail_detail/mail_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/fake_webview_platform.dart';
import 'helpers/test_db.dart';

/// Bildirime dokunan kullanıcı, tam eşitleme bitmeden DOĞRUDAN hedef iletiye
/// düşer; Gelen Kutusu'nda bırakılmaz.
///
/// Gerçek veritabanı, repository'ler ve gezinme kullanılır; yalnızca ağ
/// (IMAP/SMTP) taklittir. "Uzun eşitleme", ana IMAP bağlantısının hiç
/// bağlanamaması ile benzetilir: eşitleme iletiyi asla getirmez, ileti yalnızca
/// hedef çözücünün ayrı bağlantısıyla gelebilir.
class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(syncControllerProvider);
    ref.watch(notificationNavigatorProvider);
    return const KaydetApp();
  }
}

void appTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 2));
  });
}

void main() {
  late AppDatabase db;
  late FakeImapService mainImap;
  late FakeImapService targetImap;
  late SecureStore secureStore;
  late AppSettingsStore settingsStore;
  late PendingNotificationIntents store;
  late int accountId;
  late int inboxId;
  var targetFetches = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    // Ana bağlantı: uzun/başarısız eşitleme — iletiyi hiç getirmez.
    mainImap = FakeImapService(
      failOnConnect: const ConnectionFailure(detail: 'sync takıldı'),
    );
    targetImap = FakeImapService();
    secureStore = InMemorySecureStore();
    settingsStore = await AppSettingsStore.create();
    store = PendingNotificationIntents();
    targetFetches = 0;
    FakeWebViewPlatform.install();
    mockPluginChannels();

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');
    inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen',
        specialUse: const Value(SpecialUse.inbox),
        uidValidity: const Value(1000),
      ),
    );
  });

  tearDown(() async {
    await mainImap.dispose();
    await targetImap.dispose();
    await db.close();
  });

  NotificationIntent remote(int uid, {String eventId = 'evt-1'}) =>
      NotificationIntent.remote(
        RemoteMailTarget(
          uid: uid,
          accountId: accountId,
          folder: 'INBOX',
          uidValidity: 1000,
          eventId: eventId,
        ),
      );

  Future<void> pumpApp(WidgetTester tester) async {
    final dedicated = DedicatedTargetFetcher(
      database: db,
      secureStore: secureStore,
      imapFactory: () => targetImap,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(mainImap),
          smtpServiceProvider.overrideWithValue(FakeSmtpService()),
          settingsStoreProvider.overrideWithValue(settingsStore),
          pendingNotificationIntentsProvider.overrideWithValue(store),
          notificationTargetResolverProvider.overrideWithValue(
            NotificationTargetResolver(
              database: db,
              fetchers: [
                ({
                  required accountId,
                  required mailbox,
                  required uid,
                  expectedUidValidity,
                }) {
                  targetFetches++;
                  return dedicated.call(
                    accountId: accountId,
                    mailbox: mailbox,
                    uid: uid,
                    expectedUidValidity: expectedUidValidity,
                  );
                },
              ],
              fetchTimeout: const Duration(seconds: 5),
              syncWait: const Duration(milliseconds: 200),
            ),
          ),
        ],
        child: const _Host(),
      ),
    );
    await tester.pump();
    // Splash (1,5 sn) + ileti çözümü + sayfa geçişi.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  int? shownMessageId(WidgetTester tester) {
    final finder = find.byType(MailDetailScreen);
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<MailDetailScreen>(finder).messageId;
  }

  group('bildirimden ileti açma', () {
    appTest(
      'soğuk açılış: ileti yerelde yok, eşitleme takılı — yine de ileti açılır',
      (tester) async {
        targetImap.seedInbox([envelope(uid: 41, subject: 'Teklif onayı')]);
        // Dokunuş, uygulama ağacı kurulmadan ÖNCE yakalanmış (main()).
        store.capture(remote(41));

        await pumpApp(tester);

        final id = (await db.messageByUid(inboxId, 41))?.id;
        expect(id, isNotNull, reason: 'ileti yalnızca kendisi çekilerek yazıldı');
        expect(shownMessageId(tester), id);
        expect(targetFetches, 1);
        // Tüm Gelen Kutusu değil, tek ileti çekildi.
        expect(await db.uidsOf(inboxId), [41]);
        expect(store.pending, isNull);
      },
    );

    appTest('ileti yerelde varsa sunucuya gidilmeden açılır', (tester) async {
      final rowId = await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: inboxId,
              dateUtc: DateTime.utc(2026, 10, 1),
              uid: const Value(7),
              subject: const Value('Yerel ileti'),
            ),
          );
      store.capture(remote(7));

      await pumpApp(tester);

      expect(shownMessageId(tester), rowId);
      expect(targetFetches, 0);
    });

    appTest('sunucuda artık olmayan ileti Gelen Kutusu\'nda sessizce bırakılmaz', (
      tester,
    ) async {
      store.capture(remote(999));

      await pumpApp(tester);

      expect(shownMessageId(tester), isNull);
      expect(find.text('Bu ileti artık kullanılamıyor.'), findsOneWidget);
    });

    appTest('aynı bildirim ikinci kez gelirse ekran tekrar açılmaz', (
      tester,
    ) async {
      targetImap.seedInbox([envelope(uid: 41)]);
      store.capture(remote(41));
      await pumpApp(tester);
      final id = shownMessageId(tester);
      expect(id, isNotNull);

      // Çift teslim: aynı sistem kimliği.
      expect(store.capture(remote(41)), isFalse);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(MailDetailScreen), findsOneWidget);
      expect(targetFetches, 1);
    });

    appTest('uygulama açıkken gelen dokunuş da aynı yoldan ileti açar', (
      tester,
    ) async {
      targetImap.seedInbox([envelope(uid: 55, subject: 'Sıcak başlangıç')]);
      await pumpApp(tester);
      expect(shownMessageId(tester), isNull);

      store.capture(remote(55, eventId: 'evt-warm'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }

      final id = (await db.messageByUid(inboxId, 55))?.id;
      expect(id, isNotNull);
      expect(shownMessageId(tester), id);
    });
  });
}
