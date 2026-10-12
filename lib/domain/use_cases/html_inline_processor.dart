import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import '../../data/services/attachment_files.dart';
import 'quoted_html.dart';

/// E-posta HTML'i içindeki yerel görsel yollarını MIME inline attachment
/// ve Content-ID (CID) yapısına dönüştüren parça.
class InlineImageItem {
  const InlineImageItem({
    required this.cid,
    required this.bytes,
    required this.filename,
    required this.sourcePath,
    this.mimeType,
  });

  final String cid;
  final Uint8List bytes;
  final String filename;
  final String sourcePath;

  /// Görselin gerçek medya türü (`data:` adresinden gelenlerde bilinir).
  /// Verilmezse dosya adının uzantısından tahmin edilir.
  final String? mimeType;
}

abstract final class HtmlInlineProcessor {
  /// Tek bir `data:` görselinin üst sınırı; fazlası MIME'a taşınmaz.
  static const int maxDataImageBytes = 10 * 1024 * 1024;

  /// HTML içindeki yerel dosya yollarını (file:// veya cihaz yolu) ve gömülü
  /// `data:image/...;base64` adreslerini arar, bunları `cid:...` referansına
  /// dönüştürür ve görsellerin baytlarını [InlineImageItem] olarak döndürür.
  ///
  /// `data:` adresleri Yanıtla/İlet ile taşınan orijinal ileti görselleridir
  /// (bkz. `QuotedHtml`): alıcı tarafta çoğu istemci `data:` adresini çizmez
  /// (Gmail ayıklar), bu yüzden gönderimde her biri Content-ID'li gerçek bir
  /// MIME parçasına dönüşür. Aynı görsel birden çok kez geçerse tek parça ve
  /// tek CID kullanılır.
  ///
  /// Uzak görseller (`http://` veya `https://`) değiştirilmez, yerinde kalır.
  /// Cihaz dosya yolları (file://, /storage/..., C:\...) HTML dışına ASLA sızmaz.
  static ({String html, List<InlineImageItem> inlines}) process(String html) {
    if (html.isEmpty || !html.contains('<img')) {
      return (html: html, inlines: const []);
    }

    final fragment = html_parser.parseFragment(html);
    final imgElements = fragment.querySelectorAll('img');
    if (imgElements.isEmpty) {
      return (html: html, inlines: const []);
    }

    final inlines = <InlineImageItem>[];
    final processedPaths = <String, String>{}; // sourcePath -> cid
    final processedData = <String, String>{}; // base64 yükü -> cid

    for (var i = 0; i < imgElements.length; i++) {
      final img = imgElements[i];
      var src = img.attributes['src']?.trim() ?? '';
      if (src.isEmpty) continue;

      // 1. Zaten cid: ise veya uzak HTTP/HTTPS URL ise dokunma
      final lower = src.toLowerCase();
      if (lower.startsWith('cid:') ||
          lower.startsWith('http://') ||
          lower.startsWith('https://')) {
        continue;
      }

      // 2. Gömülü data: görseli -> Content-ID'li inline parça
      if (lower.startsWith('data:')) {
        final cid = _inlineDataImage(src, i, inlines, processedData);
        if (cid == null) {
          // Çözülemeyen/desteklenmeyen data: adresi alıcıya taşınmaz.
          img.attributes.remove('src');
          img.attributes['alt'] = 'Görsel bulunamadı';
        } else {
          img.attributes['src'] = 'cid:$cid';
        }
        continue;
      }

      // 3. Yerel dosya yolu (file:// önekini temizle)
      var localPath = src;
      if (lower.startsWith('file://')) {
        localPath = src.substring(7);
        // Windows file:///C:/... formatını düzelt
        if (localPath.startsWith('/') &&
            localPath.length > 3 &&
            localPath[2] == ':') {
          localPath = localPath.substring(1);
        }
      }

      // 4. Dosyanın varlığını kontrol et
      final file = File(localPath);
      if (!file.existsSync()) {
        // Dosya bulunamadıysa cihaz yolunu gizlemek için src temizlenir
        img.attributes.remove('src');
        img.attributes['alt'] = 'Görsel bulunamadı';
        continue;
      }

      // 5. Aynı yerel dosya birden fazla kullanıldıysa aynı CID kullanılır
      final String cid;
      if (processedPaths.containsKey(localPath)) {
        cid = processedPaths[localPath]!;
      } else {
        final hash = file.path.hashCode.abs().toRadixString(16).padLeft(8, '0');
        cid = 'sig_${hash}_$i@kaydet.local';
        processedPaths[localPath] = cid;

        final bytes = file.readAsBytesSync();
        final rawName = p.basename(localPath);
        final cleanName = AttachmentFiles.cleanPickedName(
          rawName,
          sourcePath: localPath,
        );
        inlines.add(
          InlineImageItem(
            cid: cid,
            bytes: bytes,
            filename: cleanName,
            sourcePath: localPath,
          ),
        );
      }

      // 6. HTML içindeki src'yi cid:... ile değiştir
      img.attributes['src'] = 'cid:$cid';
    }

    final processedHtml = fragment.outerHtml;
    return (html: processedHtml, inlines: inlines);
  }

  /// `data:image/...;base64,...` adresini çözüp [inlines]'e ekler ve CID'ini
  /// döndürür; geçersizse `null`.
  static String? _inlineDataImage(
    String src,
    int index,
    List<InlineImageItem> inlines,
    Map<String, String> seen,
  ) {
    final match = QuotedHtml.dataImagePrefix.firstMatch(src);
    if (match == null) return null;
    final mime = match.group(1)!.toLowerCase();
    if (!QuotedHtml.dataImageMimes.contains(mime)) return null;

    final payload = src.substring(match.end).replaceAll(RegExp(r'\s+'), '');
    final known = seen[payload];
    if (known != null) return known;

    final Uint8List bytes;
    try {
      bytes = base64.decode(base64.normalize(Uri.decodeFull(payload)));
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty || bytes.length > maxDataImageBytes) return null;

    final normalizedMime = switch (mime) {
      'image/jpg' || 'image/pjpeg' => 'image/jpeg',
      _ => mime,
    };
    final ext = switch (normalizedMime) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'png',
    };
    final number = (inlines.length + 1).toString().padLeft(3, '0');
    final hash = payload.hashCode.abs().toRadixString(16).padLeft(8, '0');
    final cid = 'img_${hash}_$index@kaydet.local';
    seen[payload] = cid;
    inlines.add(
      InlineImageItem(
        cid: cid,
        bytes: bytes,
        filename: 'image$number.$ext',
        sourcePath: '',
        mimeType: normalizedMime,
      ),
    );
    return cid;
  }
}
