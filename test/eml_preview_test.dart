// ignore_for_file: depend_on_referenced_packages
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/use_cases/attachment_type.dart';
import 'package:kaydet/ui/core/widgets/attachment_icon.dart';
import 'package:kaydet/ui/features/attachment_preview/attachment_preview_screen.dart';
import 'package:kaydet/ui/features/attachment_preview/eml_preview_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'helpers/fake_webview_platform.dart';

void main() {
  late FakeWebViewPlatform fakePlatform;

  setUpAll(() {
    mockPluginChannels();
  });

  setUp(() {
    fakePlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = fakePlatform;
  });

  group('AttachmentType EML Detection', () {
    test('detects .eml file extension in lowercase, uppercase and mixed case', () {
      expect(
        AttachmentType.resolve(mimeType: 'application/octet-stream', fileName: 'fatura.eml'),
        AttachmentKind.email,
      );
      expect(
        AttachmentType.resolve(mimeType: 'application/octet-stream', fileName: 'FATURA.EML'),
        AttachmentKind.email,
      );
      expect(
        AttachmentType.resolve(mimeType: '', fileName: 'iletilen.Eml'),
        AttachmentKind.email,
      );
    });

    test('detects message/rfc822 and application/eml MIME types even without extension', () {
      expect(
        AttachmentType.resolve(mimeType: 'message/rfc822', fileName: 'isimsiz_posta'),
        AttachmentKind.email,
      );
      expect(
        AttachmentType.resolve(mimeType: 'application/eml; charset=utf-8', fileName: 'dosya'),
        AttachmentKind.email,
      );
    });

    test('isEml returns true for all supported EML indicators', () {
      expect(AttachmentType.isEml(mimeType: 'message/rfc822', fileName: 'test.dat'), isTrue);
      expect(AttachmentType.isEml(mimeType: 'application/eml', fileName: 'test.bin'), isTrue);
      expect(AttachmentType.isEml(mimeType: '', fileName: 'posta.eml'), isTrue);
      expect(AttachmentType.isEml(mimeType: 'application/pdf', fileName: 'rapor.pdf'), isFalse);
    });

    test('label returns EML badge for .eml or message/rfc822', () {
      expect(AttachmentType.label('fatura.eml'), 'EML');
      expect(AttachmentType.label('fatura.EML'), 'EML');
      expect(AttachmentType.label('isimsiz', 'message/rfc822'), 'EML');
      expect(AttachmentType.label('rapor.pdf'), 'PDF');
    });

    test('attachmentIconData returns LucideIcons.mail for email kind', () {
      expect(attachmentIconData(AttachmentKind.email), LucideIcons.mail);
    });
  });

  group('EmlParser', () {
    test('parses basic text EML headers and text body', () {
      final raw = [
        'From: "Ahmet Yilmaz" <ahmet@kaydet.test>',
        'To: "Mehmet Demir" <mehmet@kaydet.test>',
        'Subject: Haftalik Durum Raporu',
        'Date: Thu, 09 Oct 2026 10:00:00 +0300',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'Proje ilerlemesi planlanan sekilde devam etmektedir.',
      ].join('\r\n');

      final parsed = EmlParser.parseText(raw);
      expect(parsed.subject, 'Haftalik Durum Raporu');
      expect(parsed.from.name, 'Ahmet Yilmaz');
      expect(parsed.from.email, 'ahmet@kaydet.test');
      expect(parsed.to.length, 1);
      expect(parsed.to.first.name, 'Mehmet Demir');
      expect(parsed.textBody, contains('Proje ilerlemesi planlanan'));
      expect(parsed.attachments, isEmpty);
    });

    test('parses multipart HTML EML and attachments', () {
      const boundary = '----=_Part_Boundary_123';
      final raw = [
        'From: "Sirket Muhasebe" <muhasebe@sirket.com>',
        'To: "Calisan" <calisan@sirket.com>',
        'Cc: "Yonetici" <yonetici@sirket.com>',
        'Subject: Maas Bordrosu Eylul',
        'Date: Fri, 10 Oct 2026 09:30:00 +0300',
        'Content-Type: multipart/mixed; boundary="$boundary"',
        '',
        '--$boundary',
        'Content-Type: text/html; charset=utf-8',
        '',
        '<html><body><h1>Sayin Calisan</h1><p>Bordronuz ektedir.</p></body></html>',
        '--$boundary',
        'Content-Type: application/pdf',
        'Content-Disposition: attachment; filename="bordro.pdf"',
        'Content-Transfer-Encoding: base64',
        '',
        'JVBERi0xLjQK',
        '--$boundary--',
      ].join('\r\n');

      final parsed = EmlParser.parseText(raw);
      expect(parsed.subject, 'Maas Bordrosu Eylul');
      expect(parsed.from.name, 'Sirket Muhasebe');
      expect(parsed.cc.length, 1);
      expect(parsed.cc.first.email, 'yonetici@sirket.com');
      expect(parsed.htmlBody, contains('Sayin Calisan'));
      expect(parsed.attachments.length, 1);
      expect(parsed.attachments.first.fileName, 'bordro.pdf');
      expect(parsed.attachments.first.mimeType, 'application/pdf');
    });

    test('parses nested message/rfc822 EML', () {
      const boundary = '----=_Part_Outer';
      final inner = [
        'From: "Alt Gonderen" <alt@test.com>',
        'Subject: Ic Mesaj',
        '',
        'Icteki metin',
      ].join('\r\n');

      final raw = [
        'From: "Dis Gonderen" <dis@test.com>',
        'Subject: Dis Mesaj',
        'Content-Type: multipart/mixed; boundary="$boundary"',
        '',
        '--$boundary',
        'Content-Type: text/plain',
        '',
        'Dis govde',
        '--$boundary',
        'Content-Type: message/rfc822',
        'Content-Disposition: attachment; filename="ic.eml"',
        '',
        inner,
        '--$boundary--',
      ].join('\r\n');

      final parsed = EmlParser.parseText(raw);
      expect(parsed.subject, 'Dis Mesaj');
      expect(parsed.attachments.length, 1);
      expect(parsed.attachments.first.fileName, 'ic.eml');
      expect(parsed.attachments.first.isNestedEml, isTrue);

      final innerParsed = EmlParser.parseBytes(parsed.attachments.first.bytes);
      expect(innerParsed.subject, 'Ic Mesaj');
      expect(innerParsed.from.email, 'alt@test.com');
      expect(innerParsed.textBody, contains('Icteki metin'));
    });

    test('handles empty and corrupt EML by throwing descriptive error', () {
      expect(() => EmlParser.parseText(''), throwsException);
      expect(() => EmlParser.parseText('   '), throwsException);
    });

    test('decodes Turkish characters properly in headers and body', () {
      final raw = [
        'From: =?UTF-8?Q?Bar=C4=B1=C5=9F_=C3=96zkan?= <baris@kaydet.test>',
        'Subject: =?UTF-8?Q?=C4=B0leti=C5=9Fim_G=C3=BCncellemesi?=',
        'Content-Type: text/plain; charset=utf-8',
        'Content-Transfer-Encoding: quoted-printable',
        '',
        'T=C3=BCrk=C3=A7e karakterler: =C5=9E, =C4=9F, =C3=BC, =C3=A7, =C3=B6, =C4=B1.',
      ].join('\r\n');

      final parsed = EmlParser.parseText(raw);
      expect(parsed.subject, 'İletişim Güncellemesi');
      expect(parsed.from.name, 'Barış Özkan');
      expect(parsed.textBody, contains('Ş, ğ, ü, ç, ö, ı.'));
    });

    test('parses multipart with preamble and does not leak MIME boundary or headers into body', () {
      const raw = '''From: Denizli Emlak <denizlie@test.com>
To: info@test.com
Subject: =?UTF-8?Q?Ta=C5=9F=C4=B1nmaz_Ticareti_Yetki_Belgesi_Eklendi?=
Date: Sat, 10 Oct 2026 13:16:00 +0300
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="B_ALT_6aca1082324c3"

This is a multi-part message in MIME format.

--B_ALT_6aca1082324c3
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

|

Evrak eklendi!

AHMET RÜÇHAN YAYLAK (REAL OFFICE20 GAYRİMENKUL), Taşınmaz Ticareti Yetki Belgesi ekledi

Belgeyi onaylama ekranına gitmek için tıklayın

Bu e-posta otomatik olarak
gönderilmiştir.

--B_ALT_6aca1082324c3
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: 8bit

<!DOCTYPE html>
<html>
<body>
<p>Evrak eklendi!</p>
<p>AHMET RÜÇHAN YAYLAK (REAL OFFICE20 GAYRİMENKUL), Taşınmaz Ticareti Yetki Belgesi ekledi</p>
<a href="https://example.com">Belgeyi onaylama ekranına gitmek için tıklayın</a>
<p>Bu e-posta otomatik olarak gönderilmiştir.</p>
</body>
</html>

--B_ALT_6aca1082324c3--
''';

      final parsed = EmlParser.parseText(raw);

      expect(parsed.subject, 'Taşınmaz Ticareti Yetki Belgesi Eklendi');
      expect(parsed.from.email, 'denizlie@test.com');

      // Neither body should leak boundaries or MIME headers
      expect(parsed.textBody, isNotNull);
      expect(parsed.textBody, isNot(contains('--B_ALT')));
      expect(parsed.textBody, isNot(contains('Content-Type:')));
      expect(parsed.textBody, isNot(contains('Content-Transfer-Encoding:')));
      expect(parsed.textBody, contains('Evrak eklendi!'));
      expect(parsed.textBody, contains('AHMET RÜÇHAN YAYLAK'));

      expect(parsed.htmlBody, isNotNull);
      expect(parsed.htmlBody, isNot(contains('--B_ALT')));
      expect(parsed.htmlBody, isNot(contains('Content-Type:')));
      expect(parsed.htmlBody, contains('Evrak eklendi!'));
      expect(parsed.htmlBody, contains('<a href="https://example.com">'));
    });

    test('recovers from missing Content-Type header when body contains multipart boundaries', () {
      const raw = '''From: Denizli Emlak <denizli@test.com>
To: info@test.com
Subject: Taşınmaz Ticareti Yetki Belgesi Eklendi
Date: Sat, 10 Oct 2026 13:16:00 +0300

--B_ALT_6aca1082324c3
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

Evrak eklendi!
AHMET RÜÇHAN YAYLAK

--B_ALT_6aca1082324c3
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: 8bit

<p>Evrak eklendi!</p>

--B_ALT_6aca1082324c3--
''';

      final parsed = EmlParser.parseText(raw);

      expect(parsed.textBody, isNot(contains('--B_ALT')));
      expect(parsed.textBody, isNot(contains('Content-Type:')));
      expect(parsed.textBody, contains('Evrak eklendi!'));
      expect(parsed.htmlBody, isNotNull);
      expect(parsed.htmlBody, contains('<p>Evrak eklendi!</p>'));
    });

    test('cleans isolated leaked boundary delimiter at top of plain text body', () {
      const raw = '''From: Test <test@test.com>
Subject: Test Isolated
Date: Sat, 10 Oct 2026 13:16:00 +0300
Content-Type: text/plain; charset=utf-8

--B_ALT_6aca1082324c3
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

Metin govdesi burada yer aliyor.
''';

      final parsed = EmlParser.parseText(raw);
      expect(parsed.textBody, isNot(contains('--B_ALT')));
      expect(parsed.textBody, isNot(contains('Content-Type: text/plain')));
      expect(parsed.textBody, contains('Metin govdesi burada yer aliyor.'));
    });
  });

  group('EmlPreviewWidget UI', () {
    testWidgets('renders parsed EML with headers, sender avatar and badges', (tester) async {
      final parsed = ParsedEmlData(
        subject: 'Haftalik Durum Raporu',
        from: (name: 'Ahmet Yilmaz', email: 'ahmet@kaydet.test'),
        to: [(name: 'Mehmet Demir', email: 'mehmet@kaydet.test')],
        cc: const [],
        bcc: const [],
        date: DateTime(2026, 10, 9, 10, 0),
        htmlBody: '<p>Gövde içeriği</p>',
        textBody: 'Gövde içeriği',
        attachments: [
          ParsedEmlAttachment(
            fileName: 'ek.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1024,
            bytes: Uint8List(0),
            isInline: false,
            isNestedEml: false,
          ),
        ],
      );

      const row = AttachmentRow(
        id: 1,
        messageId: 1,
        partId: '1',
        fileName: 'rapor.eml',
        mimeType: 'message/rfc822',
        sizeBytes: 250,
        isInline: false,
        isOutgoing: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmlPreviewWidget(
              path: '/dummy.eml',
              attachment: row,
              initialData: parsed,
            ),
          ),
        ),
      );

      await tester.pump();

      // Subject & sender
      expect(find.text('Haftalik Durum Raporu'), findsOneWidget);
      expect(find.text('Ahmet Yilmaz'), findsOneWidget);
      expect(find.text('İletilen E-posta — rapor'), findsOneWidget);

      // Recipient
      expect(find.text('Kime: Mehmet Demir'), findsOneWidget);

      // Inner attachment list
      expect(find.text('Ekler (1)'), findsOneWidget);
      expect(find.text('ek.pdf'), findsOneWidget);

      // Webview loaded HTML
      expect(fakePlatform.lastMessageHtml, contains('Gövde içeriği'));
    });

    testWidgets('shows friendly error state when EML file does not exist or fails', (tester) async {
      const row = AttachmentRow(
        id: 3,
        messageId: 1,
        partId: '3',
        fileName: 'nonexistent.eml',
        mimeType: 'message/rfc822',
        sizeBytes: 0,
        isInline: false,
        isOutgoing: false,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmlPreviewWidget(
              path: '/does_not_exist_xyz.eml',
              attachment: row,
            ),
          ),
        ),
      );

      // Allow file check to fail
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(find.text('Bu mail dosyası önizlenemiyor'), findsOneWidget);
      expect(find.textContaining('Dosya bozuk olabilir'), findsOneWidget);
    });

    testWidgets('expands and collapses details with CC, BCC, Message-ID', (tester) async {
      final parsed = ParsedEmlData(
        subject: 'Toplanti Notlari',
        from: (name: 'Yonetici', email: 'yonetici@kaydet.test'),
        to: [(name: 'Uye Bir', email: 'bir@kaydet.test')],
        cc: [(name: 'Gozlemci', email: 'gozlemci@kaydet.test')],
        bcc: [(name: 'Denetmen', email: 'denetmen@kaydet.test')],
        messageId: '<msg-12345@kaydet.test>',
        replyTo: (name: 'Destek', email: 'destek@kaydet.test'),
        date: DateTime(2026, 10, 9, 14, 0),
        htmlBody: '<p>Notlar</p>',
        attachments: const [],
      );

      const row = AttachmentRow(
        id: 4,
        messageId: 1,
        partId: '4',
        fileName: 'toplanti.eml',
        mimeType: 'message/rfc822',
        sizeBytes: 300,
        isInline: false,
        isOutgoing: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmlPreviewWidget(
              path: '/dummy.eml',
              attachment: row,
              initialData: parsed,
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Ayrıntılar'), findsOneWidget);
      expect(find.text('İleti Kimliği:'), findsNothing);

      // Tap "Ayrıntılar" to expand
      await tester.tap(find.text('Ayrıntılar'));
      await tester.pump();

      expect(find.text('İleti Kimliği:'), findsOneWidget);
      expect(find.text('<msg-12345@kaydet.test>'), findsOneWidget);
      expect(find.text('Bilgi (CC):'), findsOneWidget);
      expect(find.text('Gizli (BCC):'), findsOneWidget);
      expect(find.text('Yanıtla:'), findsOneWidget);
    });

    testWidgets('WebViewWidget has EagerGestureRecognizer to prevent scroll conflict with PageView', (tester) async {
      final parsed = ParsedEmlData(
        subject: 'Gesture Test',
        from: (name: 'Ahmet', email: 'ahmet@kaydet.test'),
        to: [(name: 'Mehmet', email: 'mehmet@kaydet.test')],
        cc: const [],
        bcc: const [],
        date: DateTime(2026, 10, 9, 10, 0),
        htmlBody: '<p>Kaydırma testi metni</p>',
        attachments: const [],
      );

      const row = AttachmentRow(
        id: 5,
        messageId: 1,
        partId: '5',
        fileName: 'gesture.eml',
        mimeType: 'message/rfc822',
        sizeBytes: 250,
        isInline: false,
        isOutgoing: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmlPreviewWidget(
              path: '/dummy.eml',
              attachment: row,
              initialData: parsed,
            ),
          ),
        ),
      );

      await tester.pump();
      await fakePlatform.untilMessageLoaded(tester);

      final webViewFinder = find.byType(WebViewWidget);
      expect(webViewFinder, findsOneWidget);
      final webViewWidget = tester.widget<WebViewWidget>(webViewFinder);
      expect(webViewWidget.gestureRecognizers, isNotNull);
      expect(
        webViewWidget.gestureRecognizers
            .any((factory) => factory.constructor() is EagerGestureRecognizer),
        isTrue,
      );
    });

    testWidgets('AttachmentPreviewScreen displays navigation chevrons for multiple attachments and navigates', (tester) async {
      final attachments = [
        const AttachmentRow(
          id: 10,
          messageId: 1,
          partId: '10',
          fileName: 'posta1.eml',
          mimeType: 'message/rfc822',
          sizeBytes: 500,
          isInline: false,
          isOutgoing: false,
        ),
        const AttachmentRow(
          id: 11,
          messageId: 1,
          partId: '11',
          fileName: 'posta2.eml',
          mimeType: 'message/rfc822',
          sizeBytes: 600,
          isInline: false,
          isOutgoing: false,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AttachmentPreviewScreen(
              attachments: attachments,
              initialIndex: 0,
              localPathOf: (att) => '/fake/${att.fileName}',
            ),
          ),
        ),
      );

      await tester.pump();

      // Pager indicator
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.byTooltip('Önceki ek'), findsOneWidget);
      expect(find.byTooltip('Sonraki ek'), findsOneWidget);

      final prevBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, LucideIcons.chevronLeft),
      );
      final nextBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, LucideIcons.chevronRight),
      );

      // İlk sayfada önceki devre dışı, sonraki aktif
      expect(prevBtn.onPressed, isNull);
      expect(nextBtn.onPressed, isNotNull);

      // Sonraki oka tıkla
      await tester.tap(find.widgetWithIcon(IconButton, LucideIcons.chevronRight));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('2 / 2'), findsOneWidget);
      final prevBtn2 = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, LucideIcons.chevronLeft),
      );
      final nextBtn2 = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, LucideIcons.chevronRight),
      );
      expect(prevBtn2.onPressed, isNotNull);
      expect(nextBtn2.onPressed, isNull);
    });
  });
}
