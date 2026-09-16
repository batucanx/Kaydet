import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/threading.dart';

void main() {
  group('referans ayrıştırma', () {
    test('köşeli parantezli kimlikleri çıkarır', () {
      expect(
        Threading.parseReferences('<a@x.com> <b@x.com>'),
        ['a@x.com', 'b@x.com'],
      );
    });

    test('satır sonu içeren katlanmış başlığı okur', () {
      expect(
        Threading.parseReferences('<a@x.com>\r\n\t<b@x.com>'),
        ['a@x.com', 'b@x.com'],
      );
    });

    test('parantezsiz biçimi de kabul eder', () {
      expect(
        Threading.parseReferences('a@x.com b@x.com'),
        ['a@x.com', 'b@x.com'],
      );
    });

    test('boş girdi güvenli', () {
      expect(Threading.parseReferences(null), isEmpty);
      expect(Threading.parseReferences('  '), isEmpty);
    });
  });

  group('konuşma ataması', () {
    test('yanıt, ata iletinin konuşmasına katılır', () {
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: '<kok@x.com>',
          inReplyTo: null,
          references: null,
          subject: 'Fiyat teklifi',
        ),
        const ThreadInput(
          localId: 2,
          messageId: '<yanit@x.com>',
          inReplyTo: '<kok@x.com>',
          references: '<kok@x.com>',
          subject: 'Re: Fiyat teklifi',
        ),
      ]);

      expect(result[1], 'kok@x.com');
      expect(result[2], 'kok@x.com');
    });

    test('üç seviyeli zincir tek konuşmada toplanır', () {
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: '<a@x.com>',
          inReplyTo: null,
          references: null,
          subject: 'Proje',
        ),
        const ThreadInput(
          localId: 2,
          messageId: '<b@x.com>',
          inReplyTo: '<a@x.com>',
          references: '<a@x.com>',
          subject: 'Re: Proje',
        ),
        const ThreadInput(
          localId: 3,
          messageId: '<c@x.com>',
          inReplyTo: '<b@x.com>',
          references: '<a@x.com> <b@x.com>',
          subject: 'Re: Re: Proje',
        ),
      ]);

      expect(result[1], result[2]);
      expect(result[2], result[3]);
    });

    test('ilgisiz iletiler ayrı konuşmalarda kalır', () {
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: '<a@x.com>',
          inReplyTo: null,
          references: null,
          subject: 'Fatura',
        ),
        const ThreadInput(
          localId: 2,
          messageId: '<b@x.com>',
          inReplyTo: null,
          references: null,
          subject: 'Toplantı',
        ),
      ]);

      expect(result[1], isNot(result[2]));
    });

    test('Message-ID olmayan iletiler konuya göre birleşir', () {
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Günlük rapor',
        ),
        const ThreadInput(
          localId: 2,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Re: Günlük rapor',
        ),
      ]);

      expect(result[1], result[2]);
    });

    test('boş konulu başlıksız iletiler TEK konuşmada toplanmaz', () {
      // Aksi hâlde konusu olmayan tüm otomatik iletiler tek bir dev
      // konuşmada birikir.
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: '',
        ),
        const ThreadInput(
          localId: 2,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: null,
        ),
      ]);

      expect(result[1], isNot(result[2]));
    });

    test('Türkçe yanıt ön ekiyle de birleşir', () {
      final result = Threading.assignThreads([
        const ThreadInput(
          localId: 1,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Sipariş durumu',
        ),
        const ThreadInput(
          localId: 2,
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Yanıt: Sipariş durumu',
        ),
      ]);

      expect(result[1], result[2]);
    });
  });

  group('kimlik normalleştirme', () {
    test('köşeli parantezleri kaldırır', () {
      expect(Threading.normalizeId('<abc@x.com>'), 'abc@x.com');
      expect(Threading.normalizeId('abc@x.com'), 'abc@x.com');
    });

    test('boş değerler null döner', () {
      expect(Threading.normalizeId(null), isNull);
      expect(Threading.normalizeId('  '), isNull);
    });
  });
}
