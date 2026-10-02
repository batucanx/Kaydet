import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

/// İleti gövdesini çözerken yanlış/eksik charset bildirimini telafi eder.
///
/// `enough_mail` gövdeyi başlıktaki charset'e göre çözer; charset yanlış
/// bildirilmişse (ör. UTF-8 denmiş ama gövde Windows-1254 ile gelmiş) ya da
/// tanınmıyorsa UTF-8'e "bozuk baytları yut" kipiyle düşer ve her Türkçe
/// karakter (ğ, ş, ı, İ, ü, ö, ç) `�` olur. Burada çözümlenmiş metinde `�`
/// varsa bölümün ham baytları yeniden çözülür: önce katı UTF-8, olmazsa
/// Windows-1254 (Türkçe).
abstract final class MailTextDecoder {
  static const _replacement = '�';

  /// [message] içindeki `text/plain` bölümünün metni.
  static String? plain(em.MimeMessage message) => _decode(
    message,
    em.MediaSubtype.textPlain,
    message.decodeTextPlainPart(),
  );

  /// [message] içindeki `text/html` bölümünün metni.
  static String? html(em.MimeMessage message) => _decode(
    message,
    em.MediaSubtype.textHtml,
    message.decodeTextHtmlPart(),
  );

  static String? _decode(
    em.MimePart root,
    em.MediaSubtype subtype,
    String? decoded,
  ) {
    if (decoded == null || !decoded.contains(_replacement)) return decoded;
    final part = _find(root, subtype);
    if (part == null) return decoded;
    try {
      return _redecode(part) ?? decoded;
    } on Object {
      return decoded;
    }
  }

  static em.MimePart? _find(em.MimePart part, em.MediaSubtype subtype) {
    if (part.mediaType.sub == subtype) return part;
    for (final child in part.parts ?? const <em.MimePart>[]) {
      final found = _find(child, subtype);
      if (found != null) return found;
    }
    return null;
  }

  static String? _redecode(em.MimePart part) {
    var bytes = part.decodeContentBinary();
    if (bytes == null) return null;
    final encoding = part
        .getHeaderValue('content-transfer-encoding')
        ?.trim()
        .toLowerCase();
    if (encoding == 'quoted-printable') bytes = _decodeQuotedPrintable(bytes);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return _decodeWindows1254(bytes);
    }
  }

  static Uint8List _decodeQuotedPrintable(Uint8List input) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < input.length) {
      final b = input[i];
      if (b != 0x3D) {
        out.addByte(b);
        i++;
        continue;
      }
      // Yumuşak satır sonu: `=` + CRLF veya LF.
      if (i + 1 < input.length && input[i + 1] == 0x0A) {
        i += 2;
        continue;
      }
      if (i + 2 < input.length &&
          input[i + 1] == 0x0D &&
          input[i + 2] == 0x0A) {
        i += 3;
        continue;
      }
      final hi = i + 1 < input.length ? _hex(input[i + 1]) : -1;
      final lo = i + 2 < input.length ? _hex(input[i + 2]) : -1;
      if (hi >= 0 && lo >= 0) {
        out.addByte(hi << 4 | lo);
        i += 3;
      } else {
        out.addByte(b);
        i++;
      }
    }
    return out.takeBytes();
  }

  static int _hex(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  // Windows-1254'ün Latin-1'den ayrılan karakterleri.
  static const _cp1254 = <int, int>{
    0x80: 0x20AC,
    0x85: 0x2026,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x96: 0x2013,
    0x97: 0x2014,
    0xD0: 0x011E, // Ğ
    0xDD: 0x0130, // İ
    0xDE: 0x015E, // Ş
    0xF0: 0x011F, // ğ
    0xFD: 0x0131, // ı
    0xFE: 0x015F, // ş
  };

  static String _decodeWindows1254(Uint8List bytes) =>
      String.fromCharCodes([for (final b in bytes) _cp1254[b] ?? b]);
}
