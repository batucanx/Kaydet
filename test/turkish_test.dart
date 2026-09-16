import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/turkish.dart';

void main() {
  group('Türkçe harf dönüşümü', () {
    test('büyük I küçük ı olur, İ küçük i olur', () {
      expect(trLower('ISI'), 'ısı');
      expect(trLower('İSTANBUL'), 'istanbul');
      expect(trLower('IĞDIR'), 'ığdır');
    });

    test('küçük i büyük İ olur, ı büyük I olur', () {
      expect(trUpper('istanbul'), 'İSTANBUL');
      expect(trUpper('ısı'), 'ISI');
      expect(trUpper('ığdır'), 'IĞDIR');
    });

    test('Dart standart dönüşümünden farklı sonuç verir', () {
      // Bu fark, uygulamanın Türkçe metinleri neden özel işlemesi
      // gerektiğinin kanıtıdır.
      expect('ISI'.toLowerCase(), isNot('ısı'));
      expect(trLower('ISI'), 'ısı');
    });
  });

  group('arama katlaması', () {
    test('Türkçe aksanlar sadeleşir', () {
      expect(foldForSearch('Şahan'), 'sahan');
      expect(foldForSearch('Gönderilmiş Öğeler'), 'gonderilmis ogeler');
      expect(foldForSearch('ÇİÇEK'), 'cicek');
      expect(foldForSearch('ığdır'), 'igdir');
    });

    test('aranan ve indekslenen metin aynı biçime iner', () {
      expect(foldForSearch('ÖZET'), foldForSearch('özet'));
      expect(foldForSearch('Toplantı'), foldForSearch('TOPLANTI'));
    });

    test('düzeltme işaretli harfler de sadeleşir', () {
      expect(foldForSearch('kâğıt'), 'kagit');
    });
  });

  group('konu normalleştirme', () {
    test('İngilizce ön ekleri kaldırır', () {
      expect(normalizeSubject('Re: Toplantı'), 'Toplantı');
      expect(normalizeSubject('FW: Toplantı'), 'Toplantı');
      expect(normalizeSubject('Fwd: Toplantı'), 'Toplantı');
    });

    test('Türkçe ön ekleri kaldırır', () {
      expect(normalizeSubject('Yanıt: Fiyat teklifi'), 'Fiyat teklifi');
      expect(normalizeSubject('Ynt: Fiyat teklifi'), 'Fiyat teklifi');
      expect(normalizeSubject('İlt: Fiyat teklifi'), 'Fiyat teklifi');
    });

    test('art arda tekrarlanan ön ekleri temizler', () {
      expect(normalizeSubject('Re: Re: Fwd: Rapor'), 'Rapor');
      expect(normalizeSubject('Yanıt: Re: Rapor'), 'Rapor');
    });

    test('sayaçlı biçimi temizler', () {
      expect(normalizeSubject('Re[2]: Rapor'), 'Rapor');
    });

    test('konunun içindeki iki nokta korunur', () {
      expect(
        normalizeSubject('Re: Proje: 2. faz'),
        'Proje: 2. faz',
      );
    });

    test('null ve boş güvenli', () {
      expect(normalizeSubject(null), '');
      expect(normalizeSubject('   '), '');
    });

    test('katlanmış başlıklardaki satır sonları tek boşluğa iner', () {
      expect(normalizeSubject('Re: Uzun\r\n  konu'), 'Uzun konu');
    });
  });

  group('adresten görünen ad', () {
    test('nokta ve alt çizgi ayracını kelimeye çevirir', () {
      expect(displayNameFromEmail('ahmet.yilmaz@firma.com'), 'Ahmet Yilmaz');
      expect(displayNameFromEmail('zeynep_kaya@firma.com'), 'Zeynep Kaya');
    });

    test('tek parçalı adresi Türkçe kuralla büyütür', () {
      // Türkçe kural: i → İ. "ismail" → "İsmail" doğru olsun diye
      // "info" → "İnfo" olur; hedef kitle Türkçe yazan kullanıcılardır.
      expect(displayNameFromEmail('info@pazarlik.com.tr'), 'İnfo');
      expect(displayNameFromEmail('ismail@firma.com'), 'İsmail');
    });
  });

  group('avatar harfi', () {
    test('addan ilk harfi alır ve büyütür', () {
      expect(avatarInitial('ahmet', null), 'A');
      expect(avatarInitial('ismail', null), 'İ');
    });

    test('ad yoksa adrese düşer', () {
      expect(avatarInitial(null, 'zeynep@x.com'), 'Z');
      expect(avatarInitial('   ', 'mehmet@x.com'), 'M');
    });

    test('harf olmayan karakterleri atlar', () {
      expect(avatarInitial('<<Kampanya>>', null), 'K');
      expect(avatarInitial('123 Destek', null), '1');
    });

    test('tamamen boşsa soru işareti döner', () {
      expect(avatarInitial(null, null), '?');
      expect(avatarInitial('', ''), '?');
    });
  });
}
