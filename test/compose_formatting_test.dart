import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/compose_formatting.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';

void main() {
  group('ComposeFontSize', () {
    test('seviyeler kontrollü px değerlerine sahiptir', () {
      expect(
        {for (final level in ComposeFontSize.values) level.name: level.px},
        {'small': 13, 'normal': 16, 'large': 20, 'extraLarge': 24},
      );
    });

    test('normal öznitelik taşımaz, diğerleri düz sayı metnidir', () {
      expect(ComposeFontSize.normal.attributeValue, isNull);
      expect(ComposeFontSize.small.attributeValue, '13');
      expect(ComposeFontSize.large.attributeValue, '20');
      expect(ComposeFontSize.extraLarge.attributeValue, '24');
    });

    test('öznitelik değeri flutter_quill\'in okuyabildiği bir sayıdır', () {
      // KÖK NEDEN REGRESYONU: flutter_quill `size`ı `double.tryParse` ile
      // okur; '18px' gibi bir değer null verir ve editörü çökertir.
      for (final level in ComposeFontSize.values) {
        final value = level.attributeValue;
        if (value == null) continue;
        expect(
          double.tryParse(value),
          isNotNull,
          reason: '"$value" flutter_quill tarafından okunamaz',
        );
      }
    });

    test('serbest CSS değerleri en yakın seviyeye oturur', () {
      ComposeFontSize? of(Object? v) => ComposeFontSize.fromAttribute(v);
      expect(of('12px'), ComposeFontSize.small);
      expect(of('13'), ComposeFontSize.small);
      expect(of('14px'), ComposeFontSize.small);
      expect(of('15px'), ComposeFontSize.normal);
      expect(of('16px'), ComposeFontSize.normal);
      expect(of('17.6'), ComposeFontSize.normal);
      expect(of('18px'), ComposeFontSize.large);
      expect(of('20px'), ComposeFontSize.large);
      expect(of('22px'), ComposeFontSize.extraLarge);
      expect(of('24px'), ComposeFontSize.extraLarge);
      expect(of(18.0), ComposeFontSize.large);
      expect(of(18), ComposeFontSize.large);
      expect(of('14pt'), ComposeFontSize.large); // 18,67px
      expect(of('1.5em'), ComposeFontSize.extraLarge); // 24px
      expect(of('150%'), ComposeFontSize.extraLarge);
    });

    test('adlandırılmış Quill/CSS boyutları', () {
      ComposeFontSize? of(Object? v) => ComposeFontSize.fromAttribute(v);
      expect(of('small'), ComposeFontSize.small);
      expect(of('normal'), ComposeFontSize.normal);
      expect(of('large'), ComposeFontSize.large);
      expect(of('huge'), ComposeFontSize.extraLarge);
      expect(of('x-large'), ComposeFontSize.large);
    });

    test('aşırı değerler uçtaki seviyeye kelepçelenir', () {
      ComposeFontSize? of(Object? v) => ComposeFontSize.fromAttribute(v);
      expect(of('500px'), ComposeFontSize.extraLarge);
      expect(of(9999), ComposeFontSize.extraLarge);
      expect(of('0.5px'), ComposeFontSize.small);
      expect(of(-20), ComposeFontSize.small);
      expect(
        ComposeFontSize.fromPx(double.infinity),
        ComposeFontSize.extraLarge,
      );
      expect(ComposeFontSize.fromPx(double.nan), ComposeFontSize.normal);
    });

    test('anlaşılamayan değer null döner, boş değer normaldir', () {
      expect(ComposeFontSize.fromAttribute(null), ComposeFontSize.normal);
      expect(ComposeFontSize.fromAttribute('abc'), isNull);
      expect(ComposeFontSize.fromAttribute('12 px x'), isNull);
      expect(ComposeFontSize.fromAttribute(''), isNull);
      expect(ComposeFontSize.fromAttribute(double.nan), isNull);
      expect(ComposeFontSize.fromAttribute(true), isNull);
      expect(ComposeFontSize.fromAttribute(const <String>[]), isNull);
    });

    test('göreli birimler üst öğenin boyutuna göre çözülür', () {
      expect(
        ComposeFontSize.fromAttribute('1.5em', parentPx: 13),
        ComposeFontSize.large, // 19,5px
      );
    });
  });

  group('ComposeLineSpacing', () {
    test('seçenekler ve öznitelik değerleri', () {
      expect(ComposeLineSpacing.normal.attributeValue, isNull);
      expect(ComposeLineSpacing.tight.attributeValue, 1.0);
      expect(ComposeLineSpacing.oneAndHalf.attributeValue, 1.5);
      expect(ComposeLineSpacing.doubled.attributeValue, 2.0);
      expect(ComposeLineSpacing.baseHeight, 1.15);
    });

    test('değerler en yakın seçeneğe oturur', () {
      ComposeLineSpacing? of(Object? v) => ComposeLineSpacing.fromAttribute(v);
      expect(of(1), ComposeLineSpacing.tight);
      expect(of(1.15), ComposeLineSpacing.normal);
      expect(of(1.3), ComposeLineSpacing.normal);
      expect(of(1.55), ComposeLineSpacing.oneAndHalf);
      expect(of(2.4), ComposeLineSpacing.doubled);
      expect(of(50), ComposeLineSpacing.doubled);
      expect(of(0.1), ComposeLineSpacing.tight);
      expect(of(null), ComposeLineSpacing.normal);
      expect(of('1.5'), isNull);
      expect(of(double.infinity), isNull);
    });
  });

  group('ComposeDeltaSanitizer', () {
    test('eski biçimdeki boyutlar okunabilir hâle gelir', () {
      final delta = Delta()
        ..insert('a', {'size': '18px'})
        ..insert('b', {'size': '12px'})
        ..insert('c', {'size': '500'})
        ..insert('d', {'size': 'huge'})
        ..insert('e', {'size': 'bozuk'})
        ..insert('\n');
      final json = ComposeDeltaSanitizer.sanitize(delta).toJson();
      expect(json, [
        {
          'insert': 'a',
          'attributes': {'size': '20'},
        },
        {
          'insert': 'b',
          'attributes': {'size': '13'},
        },
        {
          'insert': 'cd',
          'attributes': {'size': '24'},
        },
        {'insert': 'e\n'},
      ]);
    });

    test('gömülü nesneler ve bilinmeyen öznitelikler atılır', () {
      final delta = Delta()
        ..insert({'image': 'https://x/y.png'})
        ..insert('metin', {
          'bold': true,
          'font': 'Comic Sans',
          'width': '500',
          'style': 'x',
          'italic': 'evet', // true değil
        })
        ..insert('\n', {'code-block': true});
      final json = ComposeDeltaSanitizer.sanitize(delta).toJson();
      expect(json, [
        {
          'insert': 'metin',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]);
    });

    test('renkler doğrulanıp #RRGGBB\'ye normalleştirilir', () {
      String? hex(Object? v) => ComposeDeltaSanitizer.normalizeHexColor(v);
      expect(hex('#ef4444'), '#EF4444');
      expect(hex('#F00'), '#FF0000');
      expect(hex('ef4444'), '#EF4444');
      // Flutter'ın #AARRGGBB'si: alfa atılır (CSS'te 8 hane #RRGGBBAA'dır).
      expect(hex('#FFEF4444'), '#EF4444');
      expect(hex('red'), isNull);
      expect(hex('#GGGGGG'), isNull);
      expect(hex('url(javascript:1)'), isNull);
      expect(hex('#EF4444;position:fixed'), isNull);
      expect(hex(5), isNull);
    });

    test('bağlantılar yalnızca güvenli şemalarla geçer', () {
      String? url(Object? v) => ComposeDeltaSanitizer.safeUrl(v);
      expect(url('https://x.com/a?b=1'), 'https://x.com/a?b=1');
      expect(url('http://x.com'), 'http://x.com');
      expect(url('mailto:a@b.com'), 'mailto:a@b.com');
      expect(url('tel:+905551112233'), 'tel:+905551112233');
      expect(url('www.x.com'), 'https://www.x.com');
      expect(url('javascript:alert(1)'), isNull);
      expect(url('JaVaScRiPt:alert(1)'), isNull);
      expect(url('data:text/html,<b>x</b>'), isNull);
      expect(url('https://x.com/"onmouseover="x'), isNull);
      expect(url('kelime'), isNull);
      expect(url(''), isNull);
      expect(url(null), isNull);
    });

    test('satır özniteliklerinde sınırlar uygulanır', () {
      final delta = Delta()
        ..insert('x')
        ..insert('\n', {
          'header': 9, // geçersiz
          'indent': 99,
          'align': 'evrimsel',
          'line-height': 1.55,
        })
        ..insert('y')
        ..insert('\n', {'header': 2, 'align': 'center', 'list': 'bullet'});
      final json = ComposeDeltaSanitizer.sanitize(delta).toJson();
      expect(json[1], {
        'insert': '\n',
        'attributes': {'indent': 8, 'line-height': 1.5},
      });
      expect(json[3], {
        'insert': '\n',
        'attributes': {'header': 2, 'align': 'center', 'list': 'bullet'},
      });
    });

    test('temizlenmiş belge yeniden temizlenince değişmez (idempotent)', () {
      final delta = Delta()
        ..insert('a', {'size': '18px', 'color': '#ff0000', 'bold': true})
        ..insert('\n', {'line-height': 1.5});
      final once = ComposeDeltaSanitizer.sanitize(delta);
      final twice = ComposeDeltaSanitizer.sanitize(once);
      expect(twice.toJson(), once.toJson());
    });
  });

  group('EmailHtmlCodec.encode', () {
    String enc(Delta delta) => EmailHtmlCodec.encode(delta);

    const base =
        'margin:0;font-family:Arial,Helvetica,sans-serif;font-size:16px;';

    test('satır bazında blok, tabanı her satırda açıkça yazar', () {
      final html = enc(Delta()..insert('bir\niki\n'));
      expect(
        html,
        '<div style="${base}line-height:1.15;">bir</div>'
        '<div style="${base}line-height:1.15;">iki</div>',
      );
    });

    test('satır aralığı YALNIZCA kendi satırına gider', () {
      final html = enc(
        Delta()
          ..insert('a')
          ..insert('\n', {'line-height': 1.5})
          ..insert('b\n')
          ..insert('c')
          ..insert('\n', {'line-height': 2.0}),
      );
      expect(html, contains('line-height:1.5;">a</div>'));
      expect(html, contains('line-height:1.15;">b</div>'));
      expect(html, contains('line-height:2;">c</div>'));
    });

    test('Quill\'in eski 1.55/1.3 değerleri seçeneklere oturur', () {
      final html = enc(
        Delta()
          ..insert('a')
          ..insert('\n', {'line-height': 1.55}),
      );
      expect(html, contains('line-height:1.5;'));
    });

    test('renk, vurgu ve boyut tek span\'da; normal boyut yazılmaz', () {
      final html = enc(
        Delta()
          ..insert('k', {
            'color': '#EF4444',
            'background': '#FEF08A',
            'size': '24',
          })
          ..insert('n', {'size': null})
          ..insert('\n'),
      );
      expect(
        html,
        contains(
          '<span style="color:#EF4444;background-color:#FEF08A;'
          'font-size:24px;">k</span>n',
        ),
      );
    });

    test('kalın içindeki boyut korunur ve etiketler iç içe doğru sıradadır', () {
      final html = enc(
        Delta()
          ..insert('x', {
            'bold': true,
            'italic': true,
            'underline': true,
            'strike': true,
            'size': '20',
          })
          ..insert('\n'),
      );
      expect(
        html,
        contains(
          '<b><i><u><s><span style="font-size:20px;">x</span></s></u></i></b>',
        ),
      );
    });

    test('boş satır <br> ile korunur, sondaki boş satırlar atılır', () {
      final html = enc(Delta()..insert('a\n\nb\n\n\n'));
      expect(
        html.replaceAll(RegExp(r' style="[^"]*"'), ''),
        '<div>a</div><div><br></div><div>b</div>',
      );
    });

    test('kullanıcı metni kaçışlanır', () {
      final html = enc(
        Delta()..insert('<script>alert("x")</script> & </div>\n'),
      );
      expect(html, isNot(contains('<script>')));
      expect(html, isNot(contains('</div> &')));
      expect(
        html,
        contains('&lt;script&gt;alert("x")&lt;/script&gt; &amp; &lt;/div&gt;'),
      );
    });

    test('ardışık ve uçtaki boşluklar &nbsp; ile korunur', () {
      String body(String text) => enc(
        Delta()..insert('$text\n'),
      ).replaceAll(RegExp(r'<div style="[^"]*">|</div>'), '');
      expect(body('a b'), 'a b');
      expect(body('a  b'), 'a &nbsp;b');
      expect(body('a   b'), 'a &nbsp; b');
      expect(body('a    b'), 'a &nbsp; &nbsp;b');
      expect(body('  a'), '&nbsp; a');
      expect(body('a '), 'a&nbsp;');
      expect(body('a\tb'), 'a&nbsp;&nbsp;&nbsp;&nbsp;b');
    });

    test('boşluk kuralı parça sınırlarını aşar', () {
      final html = enc(
        Delta()
          ..insert('a ')
          ..insert(' b', {'bold': true})
          ..insert('\n'),
      );
      expect(html, contains('a <b>&nbsp;b</b>'));
    });

    test('denetim karakterleri temizlenir', () {
      final html = enc(Delta()..insert('a\u0000b\u0007c\n'));
      expect(html, contains('>abc</div>'));
    });

    test('hizalama ve girinti satır stilinde', () {
      final html = enc(
        Delta()
          ..insert('a')
          ..insert('\n', {'align': 'center', 'indent': 2})
          ..insert('b')
          ..insert('\n', {'align': 'right'}),
      );
      expect(html, contains('text-align:center;margin-left:64px;">a</div>'));
      expect(html, contains('text-align:right;">b</div>'));
    });

    test('başlıklar editördeki boyutta ve kalın', () {
      final html = enc(
        Delta()
          ..insert('Başlık')
          ..insert('\n', {'header': 3}),
      );
      expect(html, contains('<h3 style="'));
      expect(html, contains('font-size:24px;'));
      expect(html, contains('font-weight:bold;'));
    });

    test('bağlantı yalnızca güvenli şemayla <a> olur', () {
      final ok = enc(
        Delta()
          ..insert('t', {'link': 'https://x.com/a?b=1&c=2'})
          ..insert('\n'),
      );
      expect(ok, contains('<a href="https://x.com/a?b=1&amp;c=2">t</a>'));
      final bad = enc(
        Delta()
          ..insert('t', {'link': 'javascript:alert(1)'})
          ..insert('\n'),
      );
      expect(bad, isNot(contains('<a ')));
      expect(bad, contains('>t</div>'));
    });

    test('bozuk renk değeri CSS\'e enjekte edilemez', () {
      final html = enc(
        Delta()
          ..insert('t', {'color': 'red;position:fixed', 'size': '99999px'})
          ..insert('\n'),
      );
      expect(html, isNot(contains('position')));
      expect(html, contains('font-size:24px;')); // kelepçelendi
    });

    test('liste ve iç içe liste', () {
      final html = enc(
        Delta()
          ..insert('bir')
          ..insert('\n', {'list': 'bullet'})
          ..insert('alt')
          ..insert('\n', {'list': 'bullet', 'indent': 1})
          ..insert('iki')
          ..insert('\n', {'list': 'bullet'})
          ..insert('a')
          ..insert('\n', {'list': 'ordered'}),
      );
      final compact = html.replaceAll(RegExp(r' style="[^"]*"'), '');
      expect(
        compact,
        '<ul><li>bir<ul><li>alt</li></ul></li><li>iki</li></ul>'
        '<ol><li>a</li></ol>',
      );
    });

    test('alıntı bloğu', () {
      final html = enc(
        Delta()
          ..insert('a')
          ..insert('\n', {'blockquote': true})
          ..insert('b')
          ..insert('\n', {'blockquote': true})
          ..insert('c\n'),
      );
      expect(RegExp('<blockquote').allMatches(html), hasLength(1));
      expect(html, contains('>a</div>'));
      expect(html.indexOf('</blockquote>'), lessThan(html.indexOf('>c</div>')));
    });

    test('yalnızca gömülü nesne içeren belge boş satır olur', () {
      final html = enc(
        Delta()
          ..insert({'image': 'x'})
          ..insert('\n'),
      );
      expect(html, isNot(contains('image')));
    });

    test('boş belge boş HTML üretir', () {
      expect(enc(Delta()..insert('\n')), '');
      expect(enc(Delta()), '');
    });
  });

  group('EmailHtmlCodec.decode (gidiş-dönüş)', () {
    void roundTrip(String name, Delta delta) {
      test(name, () {
        final html = EmailHtmlCodec.encode(delta);
        final back = EmailHtmlCodec.decode(html);
        expect(back.toJson(), delta.toJson(), reason: html);
      });
    }

    roundTrip('düz metin', Delta()..insert('Merhaba\nDünya\n'));

    roundTrip(
      'renk + boyut + kalın',
      Delta()
        ..insert('Kırmızı büyük', {
          'color': '#EF4444',
          'size': '20',
          'bold': true,
        })
        ..insert(' normal ')
        ..insert('küçük', {'size': '13', 'italic': true, 'underline': true})
        ..insert('\n'),
    );

    roundTrip(
      'satır bazında satır aralığı (eski kodlayıcı bunu kaybediyordu)',
      Delta()
        ..insert('a')
        ..insert('\n', {'line-height': 1.5})
        ..insert('b\n')
        ..insert('c')
        ..insert('\n', {'line-height': 2.0})
        ..insert('d')
        ..insert('\n', {'line-height': 1.0}),
    );

    roundTrip(
      'boş satırlar ve hizalama',
      Delta()
        ..insert('bir\n\n')
        ..insert('orta')
        ..insert('\n', {'align': 'center'})
        ..insert('\n')
        ..insert('sağ')
        ..insert('\n', {'align': 'right', 'line-height': 1.5})
        ..insert('son\n'),
    );

    roundTrip(
      'boşluklar',
      Delta()
        ..insert('a  b   c\n')
        ..insert('  girintili\n')
        ..insert('a ')
        ..insert(' b', {'bold': true})
        ..insert('\n'),
    );

    roundTrip('özel karakterler', Delta()..insert('<b> & "q" \' ş ğ İ ı 😀\n'));

    roundTrip(
      'bağlantı, üstü çizili, üst/alt simge, vurgu',
      Delta()
        ..insert('site', {'link': 'https://x.com/a?b=1&c=2'})
        ..insert(' ')
        ..insert('sil', {'strike': true})
        ..insert(' ')
        ..insert('2', {'script': 'super'})
        ..insert(' ')
        ..insert('vurgulu', {'background': '#FEF08A'})
        ..insert('\n'),
    );

    roundTrip(
      'başlık, girinti, liste, iç içe liste, alıntı',
      Delta()
        ..insert('Başlık')
        ..insert('\n', {'header': 2})
        ..insert('girintili')
        ..insert('\n', {'indent': 2})
        ..insert('bir')
        ..insert('\n', {'list': 'bullet'})
        ..insert('alt')
        ..insert('\n', {'list': 'bullet', 'indent': 1})
        ..insert('iki')
        ..insert('\n', {'list': 'bullet'})
        ..insert('sıralı')
        ..insert('\n', {'list': 'ordered'})
        ..insert('alıntı')
        ..insert('\n', {'blockquote': true})
        ..insert('son\n'),
    );

    test('Delta her zaman \\n ile biter', () {
      for (final html in [
        '',
        '   ',
        '<div></div>',
        'sadece metin',
        '<b>x</b>',
      ]) {
        final ops = EmailHtmlCodec.decode(html).toList();
        expect(ops.last.data, endsWith('\n'), reason: html);
      }
    });
  });

  group('EmailHtmlCodec.decode (yabancı HTML)', () {
    Delta dec(String html) => EmailHtmlCodec.decode(html);

    test('Gmail biçimi: div + <br>, rgb() renk, pt boyut', () {
      final delta = dec(
        '<div dir="ltr">Merhaba<br><br>'
        '<span style="color:rgb(255,0,0);font-size:14pt">Kırmızı</span></div>',
      );
      expect(delta.toJson(), [
        {'insert': 'Merhaba\n\n'},
        {
          'insert': 'Kırmızı',
          'attributes': {'color': '#FF0000', 'size': '20'},
        },
        {'insert': '\n'},
      ]);
    });

    test('Outlook biçimi: <p> + inline stiller', () {
      final delta = dec(
        '<p style="margin:0;line-height:150%;text-align:center">'
        '<b><span style="font-size:24px">Başlık</span></b></p>'
        '<p style="margin:0"><br></p>'
        '<p style="margin:0">Metin</p>',
      );
      expect(delta.toJson(), [
        {
          'insert': 'Başlık',
          'attributes': {'bold': true, 'size': '24'},
        },
        {
          'insert': '\n',
          'attributes': {'align': 'center', 'line-height': 1.5},
        },
        {'insert': '\nMetin\n'},
      ]);
    });

    test('sondaki <br> fazladan satır üretmez', () {
      expect(dec('<div>a<br></div><div>b</div>').toJson(), [
        {'insert': 'a\nb\n'},
      ]);
    });

    test('satır aralığı px/em/normal biçimlerinden çözülür', () {
      double? height(String css) {
        final delta = dec('<div style="$css">x</div>');
        return delta.toList().last.attributes?['line-height'] as double?;
      }

      expect(height('line-height:24px'), 1.5); // 16px taban
      expect(height('line-height:2'), 2.0);
      expect(height('line-height:1.5em'), 1.5);
      expect(height('line-height:normal'), isNull);
      expect(height('line-height:1.15'), isNull);
      expect(height('line-height:inherit'), isNull);
    });

    test('kapsayıcı div\'in satır aralığı iç satırlara miras kalır', () {
      final delta = dec(
        '<div style="line-height:1.5"><div>a</div><div>b</div></div>',
      );
      expect(delta.toJson(), [
        {'insert': 'a'},
        {
          'insert': '\n',
          'attributes': {'line-height': 1.5},
        },
        {'insert': 'b'},
        {
          'insert': '\n',
          'attributes': {'line-height': 1.5},
        },
      ]);
    });

    test('aşırı ve anlamsız boyutlar kontrollü seviyelere iner', () {
      final delta = dec(
        '<div><span style="font-size:9999px">a</span>'
        '<span style="font-size:1px">b</span>'
        '<span style="font-size:garip">c</span>'
        '<span style="font-size:500%">d</span></div>',
      );
      expect(delta.toJson(), [
        {
          'insert': 'a',
          'attributes': {'size': '24'},
        },
        {
          'insert': 'b',
          'attributes': {'size': '13'},
        },
        {'insert': 'c'},
        {
          'insert': 'd',
          'attributes': {'size': '24'},
        },
        {'insert': '\n'},
      ]);
    });

    test('eski <font color size> etiketi', () {
      final delta = dec('<div><font color="#00ff00" size="5">x</font></div>');
      expect(delta.toJson(), [
        {
          'insert': 'x',
          'attributes': {'color': '#00FF00', 'size': '24'},
        },
        {'insert': '\n'},
      ]);
    });

    test('script/style/görsel/tehlikeli bağlantılar atılır', () {
      final delta = dec(
        '<style>b{color:red}</style><script>alert(1)</script>'
        '<div>a<img src="x.png"><a href="javascript:alert(1)">b</a>'
        '<a href="https://ok.com">c</a></div>',
      );
      expect(delta.toJson(), [
        {'insert': 'ab'},
        {
          'insert': 'c',
          'attributes': {'link': 'https://ok.com'},
        },
        {'insert': '\n'},
      ]);
    });

    test('girinti margin-left\'ten okunur', () {
      final delta = dec('<div style="margin-left:64px">x</div>');
      expect(delta.toList().last.attributes, {'indent': 2});
    });

    test('bozuk/yarım HTML asla istisna fırlatmaz', () {
      final inputs = [
        '<div><b>kapanmamış',
        '</div></span></b>',
        '<<<>>>',
        '<div style="font-size:;color:;;;:">x</div>',
        '<div style="font-size:999999999999999999999px">x</div>',
        '<span style="color:rgb(999,0,0)">x</span>',
        '<span style="line-height:1e999">x</span>',
        '&nbsp;&nbsp;&#0;&#x110000;',
        '<table><tr><td>a</td><td>b</td></tr></table>',
        '<ul><li>a<ul><li>b</li></ul></li></ul>',
        '<ol><ol><ol><li>derin</li></ol></ol></ol>',
        '\u0000\u0001',
        List.filled(400, '<div>').join(),
      ];
      for (final html in inputs) {
        expect(
          () => EmailHtmlCodec.decode(html),
          returnsNormally,
          reason: html.length > 80 ? html.substring(0, 80) : html,
        );
      }
    });

    test('çözücünün çıktısı sanitizer\'dan geçirilince değişmez', () {
      final delta = dec(
        '<div style="line-height:24px;text-align:center">'
        '<b><span style="color:rgb(1,2,3);font-size:18pt">x</span></b></div>'
        '<ul><li>a</li></ul>',
      );
      expect(ComposeDeltaSanitizer.sanitize(delta).toJson(), delta.toJson());
    });
  });
}
