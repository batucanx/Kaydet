import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/features/compose/attachment_reminder.dart';

void main() {
  group('AttachmentReminder', () {
    test('ek bildiren Türkçe ifadeleri doğru tespit eder', () {
      expect(
        AttachmentReminder.containsKeyword('Dosya ekte bilgilerinize sunulmuştur.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('Faturanız ektedir.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekteki belgeleri inceleyiniz.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('İstediğiniz raporu ekledim.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('Sunumu ekliyorum.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('İlişikteki formu doldurunuz.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekli dosyayı kontrol edin.'),
        isTrue,
      );
    });

    test('ek bildiren İngilizce ifadeleri doğru tespit eder', () {
      expect(
        AttachmentReminder.containsKeyword('Please find attached the report.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('See the attachment for details.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('I am attaching the invoice.'),
        isTrue,
      );
      expect(
        AttachmentReminder.containsKeyword('Enclosed please find the documents.'),
        isTrue,
      );
    });

    test('yanıltıcı benzer sözcüklerde false positive üretmez', () {
      expect(
        AttachmentReminder.containsKeyword('Ekim ayı toplantısı yapılacak.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekibimiz konuyu inceliyor.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekstra bir bilgiye gerek yoktur.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekran görüntüsünü açamadım.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Ekonomik gelişmeler değerlendirildi.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Destekleriniz için çok teşekkür ederiz.'),
        isFalse,
      );
      expect(
        AttachmentReminder.containsKeyword('Fırından sıcak ekmek aldım.'),
        isFalse,
      );
    });

    test('ek zaten varsa uyarı vermez', () {
      expect(
        AttachmentReminder.shouldWarn(
          subject: 'Fatura',
          body: 'Faturanız ektedir.',
          hasAttachments: true,
        ),
        isFalse,
      );
    });

    test('konuda ekten bahsedilmişse ama dosya yoksa uyarır', () {
      expect(
        AttachmentReminder.shouldWarn(
          subject: 'Ekli Rapor',
          body: 'Merhaba, iyi günler.',
          hasAttachments: false,
        ),
        isTrue,
      );
    });

    test('yanıt/iletmede alıntıdaki ek kelimesi kullanıcıyı yanıltmaz', () {
      const fullReplyBody = '''
Teşekkürler, kontrol edip döneceğim.

27 Eylül 2026 tarihinde Ali <ali@example.com> yazdı:
> Merhaba,
> İlgili dosya ektedir.
''';

      expect(
        AttachmentReminder.shouldWarn(
          subject: 'Re: Rapor',
          body: fullReplyBody,
          hasAttachments: false,
          isReplyOrForward: true,
        ),
        isFalse,
      );
    });

    test('yanıtta kullanıcının kendisi yeni ekten bahsedip eklemediyse uyarır', () {
      const fullReplyBody = '''
Yeni revizeyi ekte gönderdim, lütfen inceleyin.

27 Eylül 2026 tarihinde Ali <ali@example.com> yazdı:
> Merhaba,
> İlk taslak nasıldı?
''';

      expect(
        AttachmentReminder.shouldWarn(
          subject: 'Re: Rapor',
          body: fullReplyBody,
          hasAttachments: false,
          isReplyOrForward: true,
        ),
        isTrue,
      );
    });
  });
}
