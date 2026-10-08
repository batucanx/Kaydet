@Timeout(Duration(seconds: 120))
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Yanıtla / Tümünü yanıtla: "Kime" alanı çip olarak dolmalı.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late AppSettingsStore settingsStore;
  late int accountId;
  late int inboxId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    settingsStore = await AppSettingsStore.create();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
      ),
    );
    inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
  });

  tearDown(() async {
    await imap.dispose();
    await db.close();
  });

  Future<int> seedMessage({
    required String fromEmail,
    String fromName = '',
    List<EmailAddress> to = const [],
    List<EmailAddress> cc = const [],
  }) async {
    await db.upsertServerMessages([
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        dateUtc: DateTime.utc(2026, 9, 14, 10, 30),
        uid: const Value(1),
        subject: const Value('Konu'),
        fromName: Value(fromName),
        fromEmail: Value(fromEmail),
        toAddrJson: Value(EmailAddress.encodeList(to)),
        ccJson: Value(EmailAddress.encodeList(cc)),
      ),
    ]);
    final rows = await db.select(db.messages).get();
    return rows.single.id;
  }

  Future<void> open(WidgetTester tester, int id, ComposeMode mode) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(InMemorySecureStore()),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ComposeScreen(replyToId: id, mode: mode),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('Yanıtla: gönderen Kime alanında çip olarak görünür', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => seedMessage(
        fromEmail: 'ahmet@gmail.com',
        fromName: 'Ahmet Yılmaz',
        to: const [EmailAddress(email: 'info@pazarlik.com.tr')],
      ),
    ))!;
    await open(tester, id, ComposeMode.reply);
    expect(find.text('Ahmet Yılmaz'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Kendi gönderdiğimiz iletiyi yanıtlayınca alıcıya gider', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => seedMessage(
        fromEmail: 'info@pazarlik.com.tr',
        to: const [EmailAddress(email: 'musteri@gmail.com', name: 'Müşteri')],
      ),
    ))!;
    await open(tester, id, ComposeMode.reply);
    expect(find.text('Müşteri'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
