import 'dart:convert';
import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/eml_parser_service.dart';

void main() {
  test('Inspect findContentInfo size on local MimeMessage for PDF and EML', () {
    final builder = em.MessageBuilder()
      ..from = [em.MailAddress('Sender', 's@test.com')]
      ..to = [em.MailAddress('Rec', 'r@test.com')]
      ..subject = 'Test';
    builder.addTextPlain('Hello');
    builder.addBinary(
      utf8.encode('PDF content bytes here'),
      em.MediaType.fromSubtype(em.MediaSubtype.applicationPdf),
      filename: 'document.pdf',
    );

    final msg = builder.buildMimeMessage();
    final source = msg.renderMessage();
    final parsed = em.MimeMessage.parseFromText(source);

    final infos = parsed.findContentInfo();
    expect(infos.first.size, 22);

    final emlMessage = '''From: sender@domain.com\r
To: receiver@domain.com\r
Subject: Forwarded Subject\r
Date: Mon, 12 Oct 2026 10:00:00 +0300\r
Content-Type: text/plain; charset=utf-8\r
\r
Inner email body here\r
''';

    final outerEml = '''From: info@denizliemlak.com\r
To: info@denizliemlak.com\r
Subject: =?utf-8?B?xLBsZXQ6IDIgaWxldGk=?=\r
Date: Mon, 12 Oct 2026 13:41:00 +0300\r
MIME-Version: 1.0\r
Content-Type: multipart/mixed; boundary="BOUNDARY123"\r
\r
--BOUNDARY123\r
Content-Type: text/plain; charset=utf-8\r
Content-Transfer-Encoding: 7bit\r
\r
İletilen 2 ileti ek (.eml) olarak ektedir.\r
Mobil İmza\r
--BOUNDARY123\r
Content-Type: message/rfc822; name="Re Fwd Ynt EXTERNAL - Re Fwd.eml"\r
Content-Disposition: attachment; filename="Re Fwd Ynt EXTERNAL - Re Fwd.eml"\r
\r
$emlMessage\r
--BOUNDARY123--''';

    final parsedOuter = em.MimeMessage.parseFromText(outerEml);
    final infos2 = parsedOuter.findContentInfo();
    final emlInfo = infos2.firstWhere((i) => i.contentType?.mediaType.sub == em.MediaSubtype.messageRfc822);

    // enough_mail provides null info.size for message/rfc822 parts:
    expect(emlInfo.size, isNull);

    // Our fallback size resolution calculates the true size from the part:
    final emlPart = parsedOuter.getPart(emlInfo.fetchId)!;
    final resolvedSize = (emlPart.mimeData is em.TextMimeData)
        ? utf8.encode((emlPart.mimeData as em.TextMimeData).text).length
        : (emlPart.mimeData is em.BinaryMimeData)
            ? (emlPart.mimeData as em.BinaryMimeData).data.length
            : 0;

    expect(resolvedSize, greaterThan(0));

    final rawText = (emlPart.mimeData as em.TextMimeData).text;
    final emlResult = EmlParserService.parseText(rawText);
    expect(emlResult.subject, 'Forwarded Subject');
    expect(emlResult.from.email, 'sender@domain.com');
    expect(emlResult.textBody?.trim(), 'Inner email body here');
  });
}
