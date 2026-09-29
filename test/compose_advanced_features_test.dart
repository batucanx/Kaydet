@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/navigation.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/quick_templates_store.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:kaydet/ui/features/compose/quick_templates_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void appTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}

void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late SecureStore secureStore;
  late AppSettingsStore settingsStore;
  late QuickTemplatesStore quickTemplatesStore;
  late int accountId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();
    settingsStore = await AppSettingsStore.create();
    quickTemplatesStore = await QuickTemplatesStore.create();

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');

    // Mailboxes oluştur (Inbox, Sent, Drafts)
    await db.into(db.mailboxes).insert(
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
  });

  Future<void> pumpCompose(
    WidgetTester tester, {
    Duration undoWindow = const Duration(milliseconds: 1),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sendUndoWindowProvider.overrideWithValue(undoWindow),
          mailUndoWindowProvider.overrideWithValue(undoWindow),
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
          quickTemplatesStoreProvider.overrideWithValue(quickTemplatesStore),
        ],
        child: const KaydetApp(),
      ),
    );
    await tester.pumpAndSettle();

    // ComposeScreen'i doğrudan aç
    rootNavigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => const ComposeScreen(mode: ComposeMode.newMessage),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ComposeScreen Gelişmiş Özellikler', () {
    appTest('Hazır Şablonlar butonuna basılınca QuickTemplatesSheet açılır ve şablon eklenebilir', (tester) async {
      await pumpCompose(tester);

      expect(find.byTooltip('Hazır Şablonlar'), findsOneWidget);
      await tester.tap(find.byTooltip('Hazır Şablonlar'));
      await tester.pumpAndSettle();

      // Alt sayfa açılmış olmalı
      expect(find.byType(QuickTemplatesSheet), findsOneWidget);
      expect(find.text('Bilgilerinizi aldım'), findsOneWidget);

      // Bir şablona dokun
      await tester.tap(find.text('Bilgilerinizi aldım'));
      await tester.pumpAndSettle();

      // Sheet kapandı, metin editöre eklendi
      expect(find.byType(QuickTemplatesSheet), findsNothing);
    });


    appTest('Metinde "ekledim" geçip ek dosya yoksa Gönder butonuna basılınca uyarı diyalogu çıkar', (tester) async {
      await pumpCompose(tester);

      // Alıcı gir
      await tester.enterText(find.byType(TextField).first, 'test@example.com');
      await tester.pumpAndSettle();

      // Konu gir: "Rapor ektedir"
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(1), 'Rapor ektedir');
      await tester.pumpAndSettle();

      // Gönder butonuna bas
      expect(find.byTooltip('Gönder'), findsOneWidget);
      await tester.tap(find.byTooltip('Gönder'));
      await tester.pumpAndSettle();

      // Unutulan ek uyarısı çıkar
      expect(find.text('Ek eklemeyi unuttunuz mu?'), findsOneWidget);
      expect(
        find.textContaining('herhangi bir ek bulunmuyor'),
        findsOneWidget,
      );

      // "Yine de Gönder" seçeneğine basınca onaylanır
      await tester.tap(find.text('Yine de Gönder'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    });
  });
}
