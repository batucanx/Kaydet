@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/inline_image_collector.dart';
import 'package:kaydet/data/services/outgoing_attachment_store.dart';
import 'package:kaydet/data/services/quick_templates_store.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Yanıtla / İlet: orijinal iletinin gömülü görselleri yazma ekranında
/// GERÇEK görsel olarak görünür; yol/`cid:` metni görünmez; gönderimde
/// Content-ID'li MIME parçalarına dönüşür.
void main() {
  const pngB64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

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
    tempDir = Directory.systemTemp.createTempSync('kaydet_quote_img_');

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

  // Veritabanındaki gövde: gömülü görseller indirmede `data:` olmuştur;
  // çözülemeyen biri (`cid:`) ve bir izleme pikseli de vardır.
  const originalHtml =
      '<table><tr><td><img src="data:image/png;base64,$pngB64" width="120">'
      '</td></tr><tr><td>Sayın müşterimiz, hesap özetiniz ektedir.</td></tr>'
      '<tr><td><img src="data:image/png;base64,$pngB64" width="80"></td></tr>'
      '<tr><td><img src="cid:kayip@example.com" width="50"></td></tr>'
      '<tr><td><img src="https://t.example.com/p.gif" width="1" height="1">'
      '</td></tr></table>';

  Future<int> seedOriginal({bool withAttachments = false}) async {
    await db.upsertServerMessages([
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        uid: const Value(101),
        dateUtc: DateTime.utc(2026, 10, 12, 10, 30),
        subject: const Value('Hesap özeti'),
        fromName: const Value('Banka'),
        fromEmail: const Value('bilgi@banka.com'),
        toAddrJson: Value(
          EmailAddress.encodeList([
            const EmailAddress(email: 'info@pazarlik.com.tr'),
          ]),
        ),
        hasAttachments: Value(withAttachments),
      ),
    ]);
    final msg = (await db.messageByUid(inboxId, 101))!;
    await db
        .into(db.messageBodies)
        .insert(
          MessageBodiesCompanion.insert(
            messageId: Value(msg.id),
            plainText: const Value('Sayın müşterimiz, hesap özetiniz ektedir.'),
            html: const Value(originalHtml),
          ),
        );
    if (withAttachments) {
      final pdf = File('${tempDir.path}/fatura.pdf')
        ..writeAsBytesSync(utf8.encode('%PDF-1.4 sahte'));
      await db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: msg.id,
          fileName: const Value('fatura.pdf'),
          mimeType: const Value('application/pdf'),
          sizeBytes: const Value(14),
          localPath: Value(pdf.path),
          isInline: const Value(false),
        ),
      );
      // Gövdedeki görselin kendi MIME parçası: ek listesine GİRMEMELİ.
      await db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: msg.id,
          fileName: const Value('logo.png'),
          mimeType: const Value('image/png'),
          sizeBytes: const Value(70),
          contentId: const Value('logo@banka.com'),
          isInline: const Value(true),
        ),
      );
    }
    return msg.id;
  }

  Future<void> pumpCompose(
    WidgetTester tester, {
    required int replyToId,
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
    await tester.pump(const Duration(milliseconds: 500));
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

  Finder editorImages() => find.descendant(
    of: find.byType(QuillEditor),
    matching: find.byType(Image),
  );

  QuillController controllerOf(WidgetTester tester) =>
      tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;

  List<String> embeddedImages(QuillController c) => c.document
      .toDelta()
      .toList()
      .where((op) => op.data is Map && (op.data as Map)['image'] != null)
      .map((op) => (op.data as Map)['image'] as String)
      .toList();

  void expectNoLeaks(QuillController c) {
    final all = jsonEncode(c.document.toDelta().toJson());
    for (final leak in ['cid:', 'file:', tempDir.path, 'blob:']) {
      expect(all, isNot(contains(leak)));
    }
  }

  group('Yanıtla / İlet gövdesinde orijinal görseller', () {
    appTest('Yanıtla: görseller gerçek görsel olarak görünür, kayıp cid yoktur', (
      tester,
    ) async {
      final id = await seedOriginal();
      await pumpCompose(tester, replyToId: id, mode: ComposeMode.reply);

      final quill = controllerOf(tester);
      expect(embeddedImages(quill), hasLength(2));
      expect(embeddedImages(quill).every((s) => s.startsWith('data:image/png')), isTrue);
      expectNoLeaks(quill);
      expect(editorImages(), findsNWidgets(2));
      expect(quill.document.toPlainText(), contains('hesap özetiniz'));
      expect(find.textContaining('cid:'), findsNothing);
      expect(find.textContaining('Görsel bulunamadı'), findsNothing);
    });

    appTest('İlet: görseller görünür, PDF ek kalır, inline parça ek olmaz', (
      tester,
    ) async {
      final id = await seedOriginal(withAttachments: true);
      await pumpCompose(tester, replyToId: id, mode: ComposeMode.forward);

      final quill = controllerOf(tester);
      expect(embeddedImages(quill), hasLength(2));
      expectNoLeaks(quill);
      expect(editorImages(), findsNWidgets(2));
      expect(find.text('fatura.pdf'), findsOneWidget);
      expect(find.text('logo.png'), findsNothing);
    });

    appTest('Gönder: HTML’deki görseller Content-ID’li MIME parçası olur', (
      tester,
    ) async {
      final id = await seedOriginal(withAttachments: true);
      await pumpCompose(tester, replyToId: id, mode: ComposeMode.forward);

      // `_send` gövdeyi aynen böyle üretir: editör belgesi → e-posta HTML'i.
      final quill = controllerOf(tester);
      final outgoing = OutgoingMessage(
        from: const EmailAddress(email: 'info@pazarlik.com.tr'),
        to: const [EmailAddress(email: 'alici@example.com')],
        subject: 'İlet: Hesap özeti',
        plainText: quill.document
            .toPlainText()
            .replaceAll('￼', '')
            .trim(),
        html: EmailHtmlCodec.encode(quill.document.toDelta()),
        attachmentPaths: ['${tempDir.path}/fatura.pdf'],
      );
      final built = await tester.runAsync(
        () => MimeBuilder.buildSourceInIsolate(outgoing),
      );
      final wire = (built! as Ok<WireMessage>).value;
      final mime = em.MimeMessage.parseFromText(wire.source);

      expect(mime.mediaType.sub, em.MediaSubtype.multipartMixed);
      final attachments = mime.findContentInfo(
        disposition: em.ContentDisposition.attachment,
      );
      expect(attachments.map((a) => a.fileName), ['fatura.pdf']);

      final html = mime.decodeTextHtmlPart()!;
      expect(html, isNot(contains('data:image')));
      expect('cid:'.allMatches(html), hasLength(2));
      final resolved = InlineImageCollector.resolve(mime, html);
      expect(resolved, isNot(contains('cid:')));
      expect('data:image/png;base64,$pngB64'.allMatches(resolved), hasLength(2));
      expect(wire.source, isNot(contains(tempDir.path)));
    });
  });
}
