import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';

/// Türkçe karakterli ek adları (toplu iletide ad konudan üretilir) SMTP'ye
/// ham 8 bit bayt olarak gitmemeli: 8BITMIME olmadan sunucu iletiyi reddeder.
void main() {
  OutgoingMessage outgoing(List<String> paths) => OutgoingMessage(
        from: const EmailAddress(email: 'me@x.com', name: 'Ben'),
        to: [const EmailAddress(email: 'r@x.com', name: 'Alıcı')],
        subject: 'İlet: ${paths.length} ileti',
        plainText: 'Ektedir.',
        attachmentPaths: paths,
      );

  test('wireFileName: ASCII ad değişmez, Türkçe ad ASCII kodlu sözcük olur', () {
    expect(MimeBuilder.wireFileName('rapor (2026).pdf'), 'rapor (2026).pdf');
    final encoded = MimeBuilder.wireFileName('İlet Şüpheli Çağrı.eml');
    expect(encoded.codeUnits.every((c) => c < 127), isTrue);
    expect(em.MailCodec.decodeHeader(encoded), 'İlet Şüpheli Çağrı.eml');
    // Uzun ad: her kodlu sözcük 75 karakter sınırında.
    final long = MimeBuilder.wireFileName('${'Çok uzun konu ' * 8}.eml');
    for (final w in long.split(' ')) {
      expect(w.length <= 75, isTrue);
    }
    expect(em.MailCodec.decodeHeader(long), '${'Çok uzun konu ' * 8}.eml');
  });

  test('.eml ve normal ek: gönderilen MIME 7 bit ASCII, rfc822 eki uzantısız, ad alıcıda çözülür', () {
    final dir = Directory.systemTemp.createTempSync('wirename_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final eml = File('${dir.path}/İlet Şüpheli Toplantı Çağrısı (2026-01-01).eml')
      ..writeAsStringSync(
        'From: a@x.com\r\nSubject: x\r\nContent-Type: text/plain\r\n\r\nmerhaba',
      );
    final pdf = File('${dir.path}/Rapor Çıktısı.pdf')
      ..writeAsBytesSync(List.generate(300, (i) => i % 256));

    final longName = ('Şirket çağrısı İğdır toplantı ' * 3).substring(0, 75);
    final longEml = File('${dir.path}/$longName.eml')
      ..writeAsStringSync(
        'From: a@x.com\r\nSubject: x\r\nContent-Type: text/plain\r\n\r\nmerhaba',
      );

    final built = MimeBuilder.build(outgoing([eml.path, pdf.path, longEml.path]));
    expect(built.isOk, isTrue);
    final source = built.valueOrNull!.source;

    expect(source.codeUnits.any((c) => c > 127), isFalse);
    expect(source, contains('message/rfc822'));

    final parsed = em.MimeMessage.parseFromText(source);
    final names = [
      for (final part in parsed.allPartsFlat)
        if (part.decodeFileName() != null) part.decodeFileName(),
    ];
    expect(names, contains('İlet Şüpheli Toplantı Çağrısı (2026-01-01)'));
    expect(names, contains('Rapor Çıktısı.pdf'));
    expect(names, contains(longName));
  });
}
