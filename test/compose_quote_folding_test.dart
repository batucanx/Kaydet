@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/outgoing_attachment_store.dart';
import 'package:kaydet/data/services/quick_templates_store.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late SecureStore secureStore;
  late AppSettingsStore settingsStore;
  late QuickTemplatesStore quickTemplatesStore;
  late int accountId;
  late int inboxId;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();
    settingsStore = await AppSettingsStore.create();
    quickTemplatesStore = await QuickTemplatesStore.create();
    tempDir = Directory.systemTemp.createTempSync('kaydet_quote_fold_');

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'batuhan@kaydet.app',
        username: 'batuhan@kaydet.app',
        imapHost: 'mail.kaydet.app',
        smtpHost: 'mail.kaydet.app',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');

    inboxId = await db.into(db.mailboxes).insert(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
    await db.into(db.mailboxes).insert(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'Sent',
        name: 'Gönderilenler',
        specialUse: const Value(SpecialUse.sent),
      ),
    );
    await db.into(db.mailboxes).insert(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'Drafts',
        name: 'Taslaklar',
        specialUse: const Value(SpecialUse.drafts),
      ),
    );
  });

  tearDown(() async {
    await db.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> seedOriginalMessage({
    String subject = 'Toplantı Notları',
    String plainText = 'Merhaba, yarın saat 10:00 toplantısı için hazır mısınız?',
    String? html,
  }) async {
    await db.upsertServerMessages([
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        uid: const Value(105),
        dateUtc: DateTime.utc(2026, 10, 14, 9, 30),
        subject: Value(subject),
        fromName: const Value('Ahmet Yılmaz'),
        fromEmail: const Value('ahmet@example.com'),
        toAddrJson: Value(
          EmailAddress.encodeList([
            const EmailAddress(email: 'batuhan@kaydet.app', name: 'Batuhan'),
          ]),
        ),
        ccJson: Value(
          EmailAddress.encodeList([
            const EmailAddress(email: 'deniz@example.com', name: 'Deniz'),
          ]),
        ),
      ),
    ]);
    final msg = (await db.messageByUid(inboxId, 105))!;
    await db.into(db.messageBodies).insert(
      MessageBodiesCompanion.insert(
        messageId: Value(msg.id),
        plainText: Value(plainText),
        html: Value(html ?? '<p>$plainText</p>'),
      ),
    );
    return msg.id;
  }

  Future<void> pumpCompose(
    WidgetTester tester, {
    int? replyToId,
    required ComposeMode mode,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          outgoingAttachmentStoreProvider.overrideWithValue(
            OutgoingAttachmentStore(
              rootProvider: () async => Directory('${tempDir.path}/outgoing'),
            ),
          ),
          sendUndoWindowProvider.overrideWithValue(
            const Duration(milliseconds: 1),
          ),
          mailUndoWindowProvider.overrideWithValue(
            const Duration(milliseconds: 1),
          ),
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
          quickTemplatesStoreProvider.overrideWithValue(quickTemplatesStore),
        ],
        child: MaterialApp(
          home: ComposeScreen(replyToId: replyToId, mode: mode),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
  }

  void appTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await body(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    });
  }

  group('Alıntı Katlama (Quote Folding) Testleri', () {
    appTest('Yeni İleti: Alıntı katlama bileşeni görünmez', (tester) async {
      await pumpCompose(tester, mode: ComposeMode.newMessage);

      final state =
          tester.state<ComposeScreenState>(find.byType(ComposeScreen));
      expect(state.hasQuotedContentForTest, isFalse);
      expect(find.byTooltip('Alıntılanan metni göster'), findsNothing);
      expect(find.byKey(const ValueKey('quoted_quill_editor')), findsNothing);
    });

    appTest(
        'Yanıtla: Başlangıçta alıntı katlıdır (···), giden gövdede alıntı tam korunur',
        (tester) async {
      final msgId = await seedOriginalMessage();
      await pumpCompose(tester, replyToId: msgId, mode: ComposeMode.reply);

      final state =
          tester.state<ComposeScreenState>(find.byType(ComposeScreen));
      expect(state.hasQuotedContentForTest, isTrue);
      expect(state.isQuoteExpandedForTest, isFalse);

      // Web/Masaüstü ile parite: '···' hap butonu var
      expect(find.byTooltip('Alıntılanan metni göster'), findsOneWidget);
      expect(find.byKey(const ValueKey('quoted_fold_toggle_button')),
          findsOneWidget);

      // Katlıyken alıntı düzenleyicisi henüz ağaçta değil
      expect(find.byKey(const ValueKey('quoted_quill_editor')), findsNothing);

      // Ancak gönderilecek düz metin ve HTML alıntıyı ve başlığını içerir
      expect(state.bodyPlainTextForTest, contains('Ahmet Yılmaz'));
      expect(state.bodyPlainTextForTest, contains('toplantısı için hazır mısınız?'));
      expect(state.bodyHtmlForTest, isNotNull);
      expect(state.bodyHtmlForTest!, contains('toplantısı için hazır mısınız?'));
    });

    appTest(
        'Açma ve Kapama (Expand/Collapse): Tıklandığında alıntı açılır ve geri kapatılabilir',
        (tester) async {
      final msgId = await seedOriginalMessage();
      await pumpCompose(tester, replyToId: msgId, mode: ComposeMode.reply);

      final state =
          tester.state<ComposeScreenState>(find.byType(ComposeScreen));

      // 1. Üç nokta düğmesine tıkla -> Aç
      await tester.tap(find.byTooltip('Alıntılanan metni göster'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.isQuoteExpandedForTest, isTrue);
      expect(find.byKey(const ValueKey('quoted_quill_editor')), findsOneWidget);
      expect(find.byTooltip('Alıntıyı gizle'), findsOneWidget);
      expect(find.byTooltip('Alıntıyı kaldır'), findsOneWidget);
      expect(find.text('Alıntılanan metin'), findsOneWidget);

      // 2. 'Alıntıyı gizle' düğmesine tıkla -> Tekrar katla
      await tester.tap(find.byTooltip('Alıntıyı gizle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.isQuoteExpandedForTest, isFalse);
      expect(find.byKey(const ValueKey('quoted_quill_editor')), findsNothing);
      expect(find.byTooltip('Alıntılanan metni göster'), findsOneWidget);
    });

    appTest('Alıntıyı Kaldır ve Geri Al (Remove & Undo)', (tester) async {
      final msgId = await seedOriginalMessage();
      await pumpCompose(tester, replyToId: msgId, mode: ComposeMode.reply);

      final state =
          tester.state<ComposeScreenState>(find.byType(ComposeScreen));

      // Aç
      await tester.tap(find.byTooltip('Alıntılanan metni göster'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Kaldır düğmesine bas
      await tester.tap(find.byTooltip('Alıntıyı kaldır'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Artık alıntı yok
      expect(state.hasQuotedContentForTest, isFalse);
      expect(find.byTooltip('Alıntılanan metni göster'), findsNothing);
      expect(state.bodyPlainTextForTest, isNot(contains('Ahmet Yılmaz')));

      // SnackBar geri al eylemi
      expect(find.text('Alıntı kaldırıldı'), findsOneWidget);
      expect(find.text('Geri Al'), findsOneWidget);

      // 'Geri Al' tıkla
      await tester.tap(find.text('Geri Al'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Alıntı geri geldi
      expect(state.hasQuotedContentForTest, isTrue);
      expect(state.bodyPlainTextForTest, contains('Ahmet Yılmaz'));
    });

    appTest('Tümünü Yanıtla ve İlet modlarında da katlama devrededir',
        (tester) async {
      final msgId = await seedOriginalMessage();

      // İlet modu
      await pumpCompose(tester, replyToId: msgId, mode: ComposeMode.forward);
      final forwardState =
          tester.state<ComposeScreenState>(find.byType(ComposeScreen));
      expect(forwardState.hasQuotedContentForTest, isTrue);
      expect(find.byTooltip('Alıntılanan metni göster'), findsOneWidget);
      expect(forwardState.bodyPlainTextForTest,
          contains('---------- İletilen ileti ----------'));
    });
  });
}
