import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/cid_resolver.dart';
import 'package:kaydet/ui/core/theme/tokens.dart';
import 'package:kaydet/ui/features/mail_detail/mail_html_document.dart';

/// Mail render laboratuvarı (bkz. `tool/mail_render_lab/README.md`).
///
/// `test/fixtures/mail_render/*` içindeki her örnek e-postayı, uygulamanın
/// WebView'a verdiği belgenin AYNISI olarak (`MailHtmlDocument.prepare` +
/// `build` + gerçek `assets/web/mail_render.js`) açık ve koyu temada
/// `build/mail_lab/docs/` altına yazar. Tarayıcıdaki denetleyici
/// (`tool/mail_render_lab/runner.html`) bunları telefon genişliğinde yükleyip
/// taşma, ezilme, görsel, kodlama ve güvenlik denetimlerini yapar.
///
/// Bu test her çalıştırmada belgeleri üretir ve yapısal güvenceleri (tek
/// viewport, CSP) doğrular; asıl görsel denetim tarayıcıda yapılır.
void main() {
  final fixtures = Directory('test/fixtures/mail_render');
  final out = Directory('build/mail_lab');

  /// Örnek dosyalardaki `{{png:GENxYÜK:RRGGBB}}` yer tutucuları gerçek,
  /// çözülebilir bir PNG'nin `data:` adresine çevrilir (elle yazılmış
  /// base64 çoğu zaman geçerli PNG olmaz ve "kırık görsel" yanılgısı üretir).
  String fillPlaceholders(String source) =>
      source.replaceAllMapped(RegExp(r'\{\{png:(\d+)x(\d+):([0-9a-f]{6})\}\}'), (
        m,
      ) {
        final png = solidPng(
          int.parse(m[1]!),
          int.parse(m[2]!),
          int.parse(m[3]!, radix: 16),
        );
        return 'data:image/png;base64,${base64.encode(png)}';
      });

  /// CID örneği için "iletinin gömülü parçaları".
  Map<String, ({String mimeType, Uint8List bytes})> cidParts() => {
    for (final id in ['logo@kaydet.test', 'bg@kaydet.test'])
      id: (mimeType: 'image/png', bytes: solidPng(100, 50, 0x6a1b9a)),
  };

  /// "Çok büyük HTML" örneği (dosyada tutulmaz).
  String hugeNewsletter() {
    final b = StringBuffer(
      '<!-- expect: Satır 1999 -->'
      '<table width="600" align="center" cellpadding="0" cellspacing="0"><tbody>',
    );
    for (var i = 0; i < 2000; i++) {
      b.write(
        '<tr><td style="padding:6px 10px;font:14px Arial;border-bottom:1px solid #ddd">'
        'Satır $i: <a href="https://example.com/p/$i?utm=x&amp;y=$i">Ürün şğüöçıİ $i</a>'
        '</td><td align="right" style="padding:6px 10px">${i * 3},00 TL</td></tr>',
      );
    }
    b.write('</tbody></table>');
    return b.toString();
  }

  setUpAll(() {
    if (out.existsSync()) out.deleteSync(recursive: true);
    Directory('${out.path}/docs').createSync(recursive: true);
  });

  test('her örnek açık ve koyu temada belgeye dönüşür', () {
    final script = File('assets/web/mail_render.js').readAsStringSync();
    final sources = <String, String>{};
    for (final f in fixtures.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final stem = name.substring(0, dot);
      var text = fillPlaceholders(f.readAsStringSync());
      if (name.endsWith('.txt')) {
        text = MailHtmlDocument.fromPlainText(text);
      } else if (stem.contains('cid')) {
        text = CidResolver.resolve(text, cidParts());
      }
      sources[stem] = text;
    }
    sources['09-cok-buyuk-html'] = hugeNewsletter();
    expect(sources.length, greaterThanOrEqualTo(15));

    final manifest = <Map<String, Object?>>[];
    var id = 0;
    for (final entry in sources.entries) {
      for (final tokens in [KaydetTokens.light, KaydetTokens.dark]) {
        final dark = tokens.isDark;
        final (body, emailSupportsDark) = MailHtmlDocument.prepare(
          entry.value,
          dark: dark,
        );
        final html = MailHtmlDocument.build(
          body: body,
          tokens: tokens,
          emailSupportsDark: emailSupportsDark,
          script: script,
          documentId: ++id,
        );
        final name = '${entry.key}-${dark ? 'dark' : 'light'}';
        File('${out.path}/docs/$name.html').writeAsStringSync(html);
        manifest.add({
          'name': name,
          'fixture': entry.key,
          'dark': dark,
          'expect':
              RegExp(r'<!--\s*expect:\s*(.*?)\s*-->')
                  .firstMatch(entry.value)
                  ?.group(1)
                  ?.split(' | ') ??
              const <String>[],
        });

        // Yapısal güvenceler: tek viewport, CSP var.
        expect(
          'name="viewport"'.allMatches(html).length,
          1,
          reason: '$name: belgede tek viewport etiketi olmalı',
        );
        expect(html, contains('Content-Security-Policy'));
      }
    }
    File(
      '${out.path}/manifest.json',
    ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(manifest));
  });
}

/// Tek renkli, geçerli bir PNG (sıkıştırılmış, CRC'li).
Uint8List solidPng(int width, int height, int rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // süzgeç: yok
    for (var x = 0; x < width; x++) {
      raw
        ..addByte((rgb >> 16) & 0xFF)
        ..addByte((rgb >> 8) & 0xFF)
        ..addByte(rgb & 0xFF);
    }
  }
  final out = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc32(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
