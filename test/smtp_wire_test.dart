import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';

/// SMTP'ye giden metin: Bcc alıcıları YALNIZCA zarfta gider, ileti
/// başlıklarında asla görünmez; eksik ek sessizce atlanmaz.
void main() {
  // Adları uzun, adresleri çok: Bcc başlığı 76 karakterde katlanır. Eski
  // gönderim yalnızca `Bcc:` satırını silip katlanmış devam satırlarını bırakıyor,
  // bunlar bir önceki başlığa (To/Cc) yapışıp gizli alıcıları ifşa ediyordu.
  const bcc = [
    EmailAddress(email: 'gizli.kisi.bir@sirket.com.tr', name: 'Gizli Kişi Bir'),
    EmailAddress(email: 'gizli.kisi.iki@sirket.com.tr', name: 'Gizli Kişi İki'),
    EmailAddress(email: 'gizli.kisi.uc@sirket.com.tr', name: 'Gizli Kişi Üç'),
    EmailAddress(email: 'gizli.kisi.dort@sirket.com.tr', name: 'Gizli Kişi Dört'),
  ];

  // Yalnızca BAŞLIK satırları aranır: rastgele üretilen sınır/ileti kimliği
  // metninde "bcc" harfleri tesadüfen geçebilir.
  bool hasBccHeader(String source) =>
      RegExp(r'^bcc:', multiLine: true, caseSensitive: false).hasMatch(source);

  // Bcc alıcılarının adres/adlarının hiçbir izi kalmamalı.
  bool leaksBcc(String source) => source.toLowerCase().contains('gizli');

  OutgoingMessage message({List<String> attachments = const []}) =>
      OutgoingMessage(
        from: const EmailAddress(email: 'ben@ornek.com', name: 'Ben'),
        to: const [EmailAddress(email: 'alici@ornek.com', name: 'Alıcı')],
        cc: const [EmailAddress(email: 'kopya@ornek.com')],
        bcc: bcc,
        subject: 'Deneme',
        plainText: 'Merhaba',
        attachmentPaths: attachments,
      );

  group('SMTP metni', () {
    test('hiçbir Bcc başlığı ya da Bcc adresi içermez', () async {
      final result = await MimeBuilder.buildForWire(message());

      final wire = (result as Ok<WireMessage>).value;
      expect(hasBccHeader(wire.source), isFalse);
      expect(leaksBcc(wire.source), isFalse);
      for (final address in bcc) {
        expect(wire.source, isNot(contains(address.email)));
      }
      // Görünen alıcılar ve kimlik yerinde.
      expect(wire.source, contains('alici@ornek.com'));
      expect(wire.source, contains('kopya@ornek.com'));
      expect(wire.messageId, isNotEmpty);
    });

    test('doğrudan build de includeBcc:false ile Bcc yazmaz', () {
      final built =
          (MimeBuilder.build(message(), includeBcc: false) as Ok<BuiltMessage>)
              .value;

      expect(hasBccHeader(built.source), isFalse);
      expect(leaksBcc(built.source), isFalse);
    });

    test('varsayılan build (taslak kopyası) Bcc\'yi korur', () {
      final built = (MimeBuilder.build(message()) as Ok<BuiltMessage>).value;

      for (final address in bcc) {
        expect(built.source, contains(address.email));
      }
    });

    test('gönderilen ileti ayrı bir isolate\'te kurulur ve ek taşır', () async {
      final dir = Directory.systemTemp.createTempSync('kaydet_smtp_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/rapor.txt')..writeAsStringSync('içerik');

      final result = await MimeBuilder.buildForWire(
        message(attachments: [file.path]),
      );

      final wire = (result as Ok<WireMessage>).value;
      expect(wire.source, contains('rapor.txt'));
      expect(hasBccHeader(wire.source), isFalse);
      expect(leaksBcc(wire.source), isFalse);
    });
  });

  group('kendi kopyamız (Gönderilenler)', () {
    test('Bcc alıcılarını başlık olarak taşır', () async {
      final wire =
          ((await MimeBuilder.buildForWire(message())) as Ok<WireMessage>)
              .value;

      final copy = MimeBuilder.withBccHeader(wire.source, bcc);

      expect(copy, startsWith('Bcc: '));
      for (final address in bcc) {
        expect(copy, contains(address.email));
      }
      // Asıl ileti bozulmadan arkasından gelir.
      expect(copy, endsWith(wire.source));
    });

    test('taslak/Gönderilenler kopyası isolate\'te kurulur, Bcc\'yi korur', () async {
      final result = await MimeBuilder.buildSourceInIsolate(
        message(attachments: ['/yok/kayip-dosya.pdf']),
        skipMissingAttachments: true,
      );

      final wire = (result as Ok<WireMessage>).value;
      expect(hasBccHeader(wire.source), isTrue);
      for (final address in bcc) {
        expect(wire.source, contains(address.email));
      }
    });

    test('Bcc yoksa metin aynen döner', () {
      expect(MimeBuilder.withBccHeader('Subject: x\r\n\r\ny', const []), 'Subject: x\r\n\r\ny');
    });
  });

  group('eksik ek', () {
    test('varsayılan olarak reddedilir: eksik dosyayla ileti gönderilmez', () {
      final result = MimeBuilder.build(
        message(attachments: ['/yok/kayip-dosya.pdf']),
      );

      expect(result, isA<Err<BuiltMessage>>());
      final failure = (result as Err<BuiltMessage>).failure;
      expect(failure, isA<AttachmentMissingFailure>());
      expect((failure as AttachmentMissingFailure).fileNames, ['kayip-dosya.pdf']);
    });

    test('gönderim isolate\'inde de reddedilir', () async {
      final result = await MimeBuilder.buildForWire(
        message(attachments: ['/yok/kayip-dosya.pdf']),
      );

      expect(result, isA<Err<WireMessage>>());
      expect(
        (result as Err<WireMessage>).failure,
        isA<AttachmentMissingFailure>(),
      );
    });

    test('yedek kopyada (taslak/Gönderilenler) atlanabilir', () {
      final result = MimeBuilder.build(
        message(attachments: ['/yok/kayip-dosya.pdf']),
        skipMissingAttachments: true,
      );

      expect(result, isA<Ok<BuiltMessage>>());
    });
  });
}
