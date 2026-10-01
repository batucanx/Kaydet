import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import '../../data/services/attachment_files.dart';

/// E-posta HTML'i içindeki yerel görsel yollarını MIME inline attachment
/// ve Content-ID (CID) yapısına dönüştüren parça.
class InlineImageItem {
  const InlineImageItem({
    required this.cid,
    required this.bytes,
    required this.filename,
    required this.sourcePath,
  });

  final String cid;
  final Uint8List bytes;
  final String filename;
  final String sourcePath;
}

abstract final class HtmlInlineProcessor {
  /// HTML içindeki yerel dosya yollarını (file:// veya cihaz yolu) arar,
  /// bunları `cid:...` referansına dönüştürür ve bulunan yerel dosyaları
  /// [InlineImageItem] olarak döndürür.
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

      // 2. Yerel dosya yolu (file:// önekini temizle)
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

      // 3. Dosyanın varlığını kontrol et
      final file = File(localPath);
      if (!file.existsSync()) {
        // Dosya bulunamadıysa cihaz yolunu gizlemek için src temizlenir
        img.attributes.remove('src');
        img.attributes['alt'] = 'Görsel bulunamadı';
        continue;
      }

      // 4. Aynı yerel dosya birden fazla kullanıldıysa aynı CID kullanılır
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

      // 5. HTML içindeki src'yi cid:... ile değiştir
      img.attributes['src'] = 'cid:$cid';
    }

    final processedHtml = fragment.outerHtml;
    return (html: processedHtml, inlines: inlines);
  }
}
