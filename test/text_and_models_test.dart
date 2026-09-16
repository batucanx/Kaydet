import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/avatar.dart';
import 'package:kaydet/core/date_format.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/text_extraction.dart';
import 'package:kaydet/domain/use_cases/threading.dart';

void main() {
  group('HTML → düz metin', () {
    test('etiketleri kaldırır, satır yapısını korur', () {
      const html = '<p>Merhaba</p><p>İkinci paragraf</p>';
      final text = TextExtraction.htmlToPlain(html);
      expect(text, contains('Merhaba'));
      expect(text, contains('İkinci paragraf'));
      expect(text, isNot(contains('<p>')));
    });

    test('script ve style içeriğini atar', () {
      const html =
          '<style>.a{color:red}</style><script>var x=1;</script><p>Metin</p>';
      final text = TextExtraction.htmlToPlain(html);
      expect(text, 'Metin');
    });

    test('HTML varlıklarını çözer', () {
      expect(
        TextExtraction.htmlToPlain('<p>Fiyat &amp; teklif&nbsp;hazır</p>'),
        'Fiyat & teklif hazır',
      );
      expect(TextExtraction.decodeEntities('&#214;zet'), 'Özet');
      expect(TextExtraction.decodeEntities('&#x130;stanbul'), 'İstanbul');
    });

    test('br etiketleri satır sonuna döner', () {
      expect(
        TextExtraction.htmlToPlain('Bir<br>İki<br/>Üç'),
        'Bir\nİki\nÜç',
      );
    });
  });

  group('önizleme metni', () {
    test('alıntılanmış yanıtı atlar', () {
      const body = 'Teşekkürler, uygundur.\n\n'
          '14 Eylül 2026 tarihinde Ahmet Yılmaz <a@x.com> yazdı:\n'
          '> Merhaba, teklifi gönderiyorum.';
      expect(TextExtraction.buildPreview(body), 'Teşekkürler, uygundur.');
    });

    test('imza ayracından sonrasını almaz', () {
      const body = 'Kısa mesaj.\n--\nAhmet Yılmaz\nGenel Müdür';
      expect(TextExtraction.buildPreview(body), 'Kısa mesaj.');
    });

    test('uzun metni kırpar ve üç nokta ekler', () {
      final body = 'a' * 300;
      final preview = TextExtraction.buildPreview(body, maxLength: 50);
      expect(preview.length, lessThanOrEqualTo(51));
      expect(preview.endsWith('…'), isTrue);
    });

    test('boş gövde boş önizleme verir', () {
      expect(TextExtraction.buildPreview(null), '');
      expect(TextExtraction.buildPreview('   \n\n  '), '');
    });

    test('yalnızca alıntıdan oluşan gövde yine de bir şey gösterir', () {
      const body = '> Sadece alıntı var.';
      expect(TextExtraction.buildPreview(body), isNotEmpty);
    });
  });

  group('uzak görsel engelleme', () {
    test('uzak görsel tespit edilir', () {
      expect(
        TextExtraction.hasRemoteImages('<img src="https://izleme/px.gif">'),
        isTrue,
      );
      expect(
        TextExtraction.hasRemoteImages('<img src="cid:gomulu">'),
        isFalse,
      );
    });

    test('engellenen görselin kaynağı kaldırılır', () {
      final stripped = TextExtraction.stripRemoteImages(
        '<img class="a" src="https://izleme/px.gif">',
      );
      expect(stripped, isNot(contains('https://izleme')));
      expect(stripped, contains('data-blocked'));
    });

    test('protokolsüz (//) adresler de tespit edilir', () {
      expect(
        TextExtraction.hasRemoteImages('<img src="//izleme.com/px.gif">'),
        isTrue,
      );
    });

    test('srcset üzerinden yüklenen adresler tespit edilir ve kaldırılır', () {
      const html =
          '<img srcset="https://izleme/a.png 1x, https://izleme/b.png 2x">';
      expect(TextExtraction.hasRemoteImages(html), isTrue);
      final stripped = TextExtraction.stripRemoteImages(html);
      expect(stripped, isNot(contains('https://izleme')));
      expect(stripped, contains('data-blocked'));
    });

    test('CSS background-image üzerinden yüklenen adresler tespit edilir '
        've kaldırılır', () {
      const html =
          '<div style="background-image:url(https://izleme/bg.png)">';
      expect(TextExtraction.hasRemoteImages(html), isTrue);
      final stripped = TextExtraction.stripRemoteImages(html);
      expect(stripped, isNot(contains('https://izleme')));
      expect(stripped, contains('background-image:none'));
    });
  });

  group('e-posta adresi', () {
    test('geçerli adresleri tanır', () {
      expect(EmailAddress.isValidEmail('info@pazarlik.com.tr'), isTrue);
      expect(EmailAddress.isValidEmail('a.b+c@alt.alan.com'), isTrue);
    });

    test('geçersiz adresleri reddeder', () {
      expect(EmailAddress.isValidEmail('bozuk'), isFalse);
      expect(EmailAddress.isValidEmail('a@b'), isFalse);
      expect(EmailAddress.isValidEmail('@alan.com'), isFalse);
      expect(EmailAddress.isValidEmail('a@@b.com'), isFalse);
    });

    test('adres listesini ayrıştırır', () {
      final list = EmailAddress.parseInput(
        'Ahmet Yılmaz <ahmet@x.com>, zeynep@y.com',
      );
      expect(list, hasLength(2));
      expect(list.first.name, 'Ahmet Yılmaz');
      expect(list.first.email, 'ahmet@x.com');
      expect(list.last.email, 'zeynep@y.com');
    });

    test('tırnak içindeki virgül adresi bölmez', () {
      final list = EmailAddress.parseInput('"Yılmaz, Ahmet" <a@x.com>');
      expect(list, hasLength(1));
      expect(list.single.name, 'Yılmaz, Ahmet');
    });

    test('noktalı virgül de ayraç sayılır', () {
      expect(EmailAddress.parseInput('a@x.com; b@y.com'), hasLength(2));
    });

    test('JSON gidiş-dönüşü bozulmaz', () {
      final original = [
        const EmailAddress(email: 'a@x.com', name: 'Ali'),
        const EmailAddress(email: 'b@y.com'),
      ];
      final decoded = EmailAddress.decodeList(
        EmailAddress.encodeList(original),
      );
      expect(decoded, hasLength(2));
      expect(decoded.first.name, 'Ali');
      expect(decoded.last.email, 'b@y.com');
    });

    test('bozuk JSON çökme yerine boş liste verir', () {
      expect(EmailAddress.decodeList('bozuk json'), isEmpty);
      expect(EmailAddress.decodeList(null), isEmpty);
    });

    test('görünen ad yoksa adresten türetilir', () {
      const address = EmailAddress(email: 'ahmet.yilmaz@x.com');
      expect(address.display, 'Ahmet Yilmaz');
    });
  });

  group('yanıt zinciri (References)', () {
    test('orijinal zincire yeni kimlik eklenir', () {
      final references = Threading.buildReferences(
        originalReferences: '<a@x.com> <b@x.com>',
        originalMessageId: '<c@x.com>',
      );
      expect(references, '<a@x.com> <b@x.com> <c@x.com>');
    });

    test('zincir yoksa tek kimlikle başlar', () {
      expect(
        Threading.buildReferences(
          originalReferences: null,
          originalMessageId: 'c@x.com',
        ),
        '<c@x.com>',
      );
    });

    test('aynı kimlik iki kez eklenmez', () {
      expect(
        Threading.buildReferences(
          originalReferences: '<a@x.com>',
          originalMessageId: '<a@x.com>',
        ),
        '<a@x.com>',
      );
    });

    test('çok uzun zincir kırpılır', () {
      final long = List.generate(40, (i) => '<m$i@x.com>').join(' ');
      final result = Threading.buildReferences(
        originalReferences: long,
        originalMessageId: '<son@x.com>',
      );
      final count = RegExp(r'<[^>]+>').allMatches(result).length;
      expect(count, lessThanOrEqualTo(20));
      // Kök referans korunur — konuşmanın başlangıcı kaybolmamalı.
      expect(result, startsWith('<m0@x.com>'));
      expect(result, endsWith('<son@x.com>'));
    });
  });

  group('tarih biçimlendirme', () {
    final now = DateTime(2026, 9, 14, 15, 0);

    test('bugünkü ileti saat gösterir', () {
      final date = DateTime(2026, 9, 14, 13, 54);
      expect(formatListDate(date, now: now), '13:54');
    });

    test('dünkü ileti "Dün" gösterir', () {
      expect(
        formatListDate(DateTime(2026, 9, 13, 10), now: now),
        'Dün',
      );
    });

    test('son hafta gün adı gösterir', () {
      // 2026-09-10 Perşembe
      expect(
        formatListDate(DateTime(2026, 9, 10, 10), now: now),
        'Per',
      );
    });

    test('aynı yıl gün ve ay gösterir', () {
      expect(
        formatListDate(DateTime(2026, 3, 5, 10), now: now),
        '5 Mar',
      );
    });

    test('geçmiş yıl tam tarih gösterir', () {
      expect(
        formatListDate(DateTime(2025, 3, 5, 10), now: now),
        '05.03.25',
      );
    });

    test('detay tarihi Türkçe ay ve gün adı içerir', () {
      final text = formatDetailDate(DateTime(2026, 9, 14, 13, 54).toUtc());
      expect(text, contains('Eylül'));
      expect(text, contains('2026'));
    });

    test('dosya boyutu Türkçe ondalık ayracı kullanır', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1,5 KB');
      expect(formatBytes(1024 * 1024 * 3), '3,0 MB');
    });

    test('göreli süre', () {
      final now = DateTime(2026, 9, 14, 15, 0);
      expect(formatRelative(now.subtract(const Duration(seconds: 10)), now: now),
          'az önce');
      expect(formatRelative(now.subtract(const Duration(minutes: 5)), now: now),
          '5 dk önce');
      expect(formatRelative(now.subtract(const Duration(hours: 3)), now: now),
          '3 sa önce');
    });
  });

  group('avatar rengi', () {
    test('aynı adres her zaman aynı tonu alır', () {
      final a = AvatarHash.toneIndex('ahmet@x.com', 'Ahmet', 15);
      final b = AvatarHash.toneIndex('ahmet@x.com', 'Başka Ad', 15);
      expect(a, b);
    });

    test('aynı harfle başlayan farklı adresler farklı ton alabilir', () {
      // React prototipindeki charCodeAt(0) yaklaşımının düzeltildiği yer.
      final tones = {
        AvatarHash.toneIndex('ahmet@x.com', null, 15),
        AvatarHash.toneIndex('ali@x.com', null, 15),
        AvatarHash.toneIndex('ayse@x.com', null, 15),
        AvatarHash.toneIndex('arda@x.com', null, 15),
      };
      expect(tones.length, greaterThan(1));
    });

    test('ton indeksi her zaman aralık içinde', () {
      for (final email in ['a@x.com', 'çok.uzun.adres@alt.alan.com.tr', '']) {
        final tone = AvatarHash.toneIndex(email, null, 15);
        expect(tone, inInclusiveRange(0, 14));
      }
    });

    test('büyük/küçük harf farkı tonu değiştirmez', () {
      expect(
        AvatarHash.toneIndex('Ahmet@X.com', null, 15),
        AvatarHash.toneIndex('ahmet@x.com', null, 15),
      );
    });

    test('dağılım makul ölçüde dengeli', () {
      final counts = <int, int>{};
      for (var i = 0; i < 1500; i++) {
        final tone = AvatarHash.toneIndex('kullanici$i@ornek.com', null, 15);
        counts[tone] = (counts[tone] ?? 0) + 1;
      }
      expect(counts.keys.length, 15);
      // Hiçbir ton toplamın üçte birinden fazlasını almamalı.
      expect(counts.values.every((c) => c < 500), isTrue);
    });
  });
}
