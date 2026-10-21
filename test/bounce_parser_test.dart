import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/bounce_parser.dart';

/// Sunucudan gelen iade (bounce) iletilerinin tanınması ve nedeni.
void main() {
  const postfixNoUser = '''
From: MAILER-DAEMON@mail.pazarlik.com.tr (Mail Delivery System)
Subject: Undelivered Mail Returned to Sender
Content-Type: multipart/report; report-type=delivery-status

--b1
Content-Description: Notification

This is the mail system at host mail.pazarlik.com.tr.

--b1
Content-Description: Delivery report

Reporting-MTA: dns; mail.pazarlik.com.tr

Final-Recipient: rfc822; yok@firma.com
Original-Recipient: rfc822;yok@firma.com
Action: failed
Status: 5.1.1
Diagnostic-Code: smtp; 550 5.1.1 <yok@firma.com>: Recipient address
    rejected: User unknown in virtual mailbox table

--b1
Content-Description: Undelivered Message Headers

Return-Path: <info@pazarlik.com.tr>
Message-ID: <1760000000.abc123@pazarlik.com.tr>
Subject: 10.52
''';

  const delayed = '''
Subject: Delivery Status Notification (Delay)

Final-Recipient: rfc822; musteri@firma.com
Action: delayed
Status: 4.4.1
Diagnostic-Code: smtp; connection timed out
Message-ID: <1760000000.abc123@pazarlik.com.tr>
''';

  const spamRejected = '''
Final-Recipient: rfc822; musteri@firma.com
Action: failed
Status: 5.7.1
Diagnostic-Code: smtp; 554 5.7.1 Message rejected as spam
''';

  const mailboxFull = '''
Final-Recipient: rfc822; musteri@firma.com
Action: failed
Status: 5.2.2
''';

  group('looksLikeBounce', () {
    test('gönderen Mailer-Daemon ise aday', () {
      expect(
        BounceParser.looksLikeBounce(
          fromEmail: 'MAILER-DAEMON@mail.pazarlik.com.tr',
          subject: 'Merhaba',
        ),
        isTrue,
      );
    });

    test('konu iade ifadesi içeriyorsa aday (Türkçe dahil)', () {
      expect(
        BounceParser.looksLikeBounce(
          fromEmail: 'x@y.com',
          subject: 'Delivery Status Notification (Failure)',
        ),
        isTrue,
      );
      expect(
        BounceParser.looksLikeBounce(
          fromEmail: 'x@y.com',
          subject: 'İletiniz teslim edilemedi',
        ),
        isTrue,
      );
    });

    test('sıradan ileti aday değil', () {
      expect(
        BounceParser.looksLikeBounce(
          fromEmail: 'ahmet@firma.com',
          fromName: 'Ahmet Yılmaz',
          subject: 'Teklif hakkında',
        ),
        isFalse,
      );
    });
  });

  group('mentionsMessageId', () {
    test('parantezli ve parantezsiz Message-ID eşleşir, büyük/küçük harf fark etmez',
        () {
      expect(
        BounceParser.mentionsMessageId(
          postfixNoUser,
          '1760000000.ABC123@pazarlik.com.tr',
        ),
        isTrue,
      );
      expect(
        BounceParser.mentionsMessageId(
          postfixNoUser,
          '<1760000000.abc123@pazarlik.com.tr>',
        ),
        isTrue,
      );
    });

    test('başka bir iletinin kimliği eşleşmez; boş kimlik hiç eşleşmez', () {
      expect(
        BounceParser.mentionsMessageId(postfixNoUser, 'baska.id@x.com'),
        isFalse,
      );
      expect(BounceParser.mentionsMessageId(postfixNoUser, '  '), isFalse);
    });
  });

  group('parse', () {
    test('olmayan adres: alıcı, Türkçe özet ve sunucu metni (katlanmış satır)',
        () {
      final report = BounceParser.parse(postfixNoUser)!;
      expect(report.reason, startsWith('yok@firma.com: Alıcı adresi bulunamadı'));
      expect(report.reason, contains('550 5.1.1'));
      expect(report.reason, contains('User unknown in virtual mailbox table'));
    });

    test('gecikme bildirimi hata sayılmaz', () {
      expect(BounceParser.parse(delayed), isNull);
    });

    test('spam reddi (5.7.x)', () {
      final report = BounceParser.parse(spamRejected)!;
      expect(report.reason, contains('spam veya güvenlik politikası'));
      expect(report.reason, contains('554 5.7.1'));
    });

    test('posta kutusu dolu (5.2.2), Diagnostic-Code olmasa da', () {
      final report = BounceParser.parse(mailboxFull)!;
      expect(
        report.reason,
        'musteri@firma.com: Alıcının posta kutusu dolu',
      );
    });

    test('biçimsiz iade: genel neden döner', () {
      final report = BounceParser.parse('Sorry, your mail bounced.')!;
      expect(report.reason, 'İleti alıcıya teslim edilemedi');
    });
  });
}
