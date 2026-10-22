import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/mail_date_parser.dart';

void main() {
  final expected = DateTime.utc(2026, 10, 21, 10, 18);

  group('parseMailDate', () {
    test('standart RFC 5322 biçimi', () {
      expect(parseMailDate('Wed, 21 Oct 2026 13:18:00 +0300'), expected);
    });

    test('iki noktalı saat dilimi UTC sayılıp saati kaydırmaz', () {
      expect(parseMailDate('Wed, 21 Oct 2026 13:18:00 +03:00'), expected);
    });

    test('GMT+hhmm ve açıklama parantezi', () {
      expect(parseMailDate('Wed, 21 Oct 2026 13:18:00 GMT+0300'), expected);
      expect(parseMailDate('Wed, 21 Oct 2026 13:18:00 +0300 (TRT)'), expected);
    });

    test('gün adı olmayan ve katlanmış (fazla boşluklu) başlık', () {
      expect(parseMailDate('21 Oct 2026 13:18:00 +0300'), expected);
      expect(
        parseMailDate('Wed,  21  Oct  2026  13:18:00  +0300\r\n'),
        expected,
      );
    });

    test('ISO 8601', () {
      expect(parseMailDate('2026-10-21T13:18:00+03:00'), expected);
      expect(parseMailDate('2026-10-21T10:18:00.000Z'), expected);
    });

    test('sonuç her zaman UTC', () {
      expect(parseMailDate('Wed, 21 Oct 2026 13:18:00 +0300')!.isUtc, isTrue);
    });

    test('okunamayan / boş değer null döner', () {
      expect(parseMailDate(null), isNull);
      expect(parseMailDate(''), isNull);
      expect(parseMailDate('   '), isNull);
      expect(parseMailDate('dün akşam'), isNull);
    });
  });

  group('parseInternalDate', () {
    test('IMAP INTERNALDATE biçimi', () {
      expect(parseInternalDate('21-Oct-2026 13:18:00 +0300'), expected);
    });

    test('tek haneli gün (baştaki boşluk) ve negatif dilim', () {
      expect(
        parseInternalDate(' 1-Oct-2026 05:18:00 -0500'),
        DateTime.utc(2026, 10, 1, 10, 18),
      );
    });

    test('boş değer null döner', () {
      expect(parseInternalDate(null), isNull);
      expect(parseInternalDate(''), isNull);
    });
  });
}
