@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNotNull;
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
    tempDir = Directory.systemTemp.createTempSync('kaydet_forward_test_');

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');

    inboxId = await db
        .into(db.mailboxes)
        .insert(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'INBOX',
            name: 'Gelen Kutusu',
            specialUse: const Value(SpecialUse.inbox),
          ),
        );
    await db
        .into(db.mailboxes)
        .insert(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'Sent',
            name: 'Gönderilenler',
            specialUse: const Value(SpecialUse.sent),
          ),
        );
    await db
        .into(db.mailboxes)
        .insert(
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

  Future<int> createOriginalMessage({
    required String subject,
    String? fromEmail,
    String? toEmail,
    String? ccEmail,
    bool hasAttachments = true,
  }) async {
    await db.upsertServerMessages([
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        uid: const Value(101),
        dateUtc: DateTime.utc(2026, 10, 12, 10, 30),
        subject: Value(subject),
        fromName: const Value('Avukat'),
        fromEmail: Value(fromEmail ?? 'gonderen@example.com'),
        toAddrJson: Value(
          EmailAddress.encodeList([
            EmailAddress(email: toEmail ?? 'info@pazarlik.com.tr'),
          ]),
        ),
        ccJson: Value(
          ccEmail != null && ccEmail.isNotEmpty
              ? EmailAddress.encodeList([EmailAddress(email: ccEmail)])
              : '[]',
        ),
        hasAttachments: Value(hasAttachments),
      ),
    ]);
    final msg = (await db.messageByUid(inboxId, 101))!;
    await db
        .into(db.messageBodies)
        .insert(
          MessageBodiesCompanion.insert(
            messageId: Value(msg.id),
            plainText: const Value('Orijinal ileti metni'),
          ),
        );
    return msg.id;
  }

  Future<void> pumpForwardCompose(
    WidgetTester tester, {
    required int replyToId,
    Duration undoWindow = const Duration(milliseconds: 1),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          outgoingAttachmentStoreProvider.overrideWithValue(
            OutgoingAttachmentStore(
              rootProvider: () async => Directory('${tempDir.path}/outgoing'),
            ),
          ),
          sendUndoWindowProvider.overrideWithValue(undoWindow),
          mailUndoWindowProvider.overrideWithValue(undoWindow),
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
          quickTemplatesStoreProvider.overrideWithValue(quickTemplatesStore),
        ],
        child: MaterialApp(
          home: ComposeScreen(replyToId: replyToId, mode: ComposeMode.forward),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('İletirken ekleri doldurma (Forward with attachments)', () {
    appTest(
      'Yerelde kayıtlı ekler iletme ekranına anında otomatik iliştirilir ve CC bilgisi eklenir',
      (tester) async {
        final msgId = await createOriginalMessage(
          subject: 'Sözleşme ve Ekler',
          fromEmail: 'avukat@hukuk.com',
          toEmail: 'info@pazarlik.com.tr',
          ccEmail: 'muhasebe@pazarlik.com.tr',
          hasAttachments: true,
        );

        final testFile = File('${tempDir.path}/sozlesme.pdf');
        testFile.writeAsStringSync('PDF içeriği');

        await db.addAttachment(
          AttachmentsCompanion.insert(
            messageId: msgId,
            fileName: const Value('sozlesme.pdf'),
            mimeType: const Value('application/pdf'),
            sizeBytes: const Value(1024),
            localPath: Value(testFile.path),
            isInline: const Value(false),
          ),
        );

        await pumpForwardCompose(tester, replyToId: msgId);

        // Ekler listesinde sozlesme.pdf hazır olarak bulunmalı
        expect(find.byTooltip('sozlesme.pdf'), findsOneWidget);

        // Alıntı katlanmış durumdadır; açılınca başlıkta Bilgi (CC) satırı görünür
        expect(find.byTooltip('Alıntılanan metni göster'), findsOneWidget);
        await tester.tap(find.byTooltip('Alıntılanan metni göster'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // İletilen ileti başlığında Bilgi (CC) satırı bulunmalı
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText().contains(
                  '---------- İletilen ileti ----------',
                ),
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText().contains(
                  'Bilgi: muhasebe@pazarlik.com.tr',
                ),
          ),
          findsOneWidget,
        );
      },
    );

    appTest('İletme ekranında ek kaldırılabilir (onRemove)', (tester) async {
      final msgId = await createOriginalMessage(
        subject: 'Teklif',
        hasAttachments: true,
      );

      final testFile = File('${tempDir.path}/teklif.pdf');
      testFile.writeAsStringSync('Teklif PDF içeriği');

      await db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: msgId,
          fileName: const Value('teklif.pdf'),
          mimeType: const Value('application/pdf'),
          sizeBytes: const Value(2048),
          localPath: Value(testFile.path),
          isInline: const Value(false),
        ),
      );

      await pumpForwardCompose(tester, replyToId: msgId);

      expect(find.byTooltip('teklif.pdf'), findsOneWidget);

      // Ekin 'Kaldır' butonuna bas
      expect(find.byTooltip('Kaldır'), findsOneWidget);
      await tester.tap(find.byTooltip('Kaldır'));
      await tester.pumpAndSettle();

      // Ek artık görünmemeli
      expect(find.byTooltip('teklif.pdf'), findsNothing);
    });

    appTest(
      'Henüz indirilmemiş ek için yükleme kartı gösterilir ve gönderilmeye çalışılırsa engellenir',
      (tester) async {
        final msgId = await createOriginalMessage(
          subject: 'Büyük Dosya',
          hasAttachments: true,
        );

        // Yerelde olmayan (localPath null) ek ekle
        await db.addAttachment(
          AttachmentsCompanion.insert(
            messageId: msgId,
            fileName: const Value('dokuman.docx'),
            mimeType: const Value(
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            ),
            sizeBytes: const Value(5000000),
            localPath: const Value(null),
            isInline: const Value(false),
          ),
        );

        // imap.bodyDelay ile indirmeyi geciktirerek pending durumunu test et
        imap.bodyDelay = const Duration(seconds: 10);

        await pumpForwardCompose(tester, replyToId: msgId);

        // Pending çipinde dosya adı ve yükleniyor göstergesi görünmeli
        // ("Hazırlanıyor…" metni artık yalnızca liste sayfasındaki satırda).
        expect(find.byTooltip('dokuman.docx'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('dokuman.docx'),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );

        // Alıcı gir ve Gönder'e bas
        final textFields = find.byType(TextField);
        await tester.enterText(textFields.first, 'alici@example.com');
        await tester.pump();

        await tester.tap(find.byTooltip('Gönder'));
        await tester.pump();

        // "Ekler hazırlanıyor, lütfen bekleyin…" uyarısı çıkmalı
        expect(
          find.text('Ekler hazırlanıyor, lütfen bekleyin…'),
          findsOneWidget,
        );

        // İptal etmek için ekin üzerindeki 'Kaldır' (X) butonuna bas
        expect(find.byTooltip('Kaldır'), findsOneWidget);
        await tester.tap(find.byTooltip('Kaldır'));
        await tester.pump();

        // Pending kartı kaldırılmış olmalı
        expect(find.byTooltip('dokuman.docx'), findsNothing);
      },
    );
  });
}
