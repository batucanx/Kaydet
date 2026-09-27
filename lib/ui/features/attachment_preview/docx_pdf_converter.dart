import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart' hide DocxParser, DocxBlock;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'docx_viewer.dart';

/// DOCX, DOC ve RTF belgelerini mevcut PDF önizleme motoruna beslemek üzere
/// yüksek aslına uygunlukla PDF formatına dönüştüren ve sonucu önbelleğe alan servis.
class DocxPdfConverter {
  const DocxPdfConverter._();

  static const String cacheDirectoryName = 'docx_preview_cache';

  /// Özel önbellek dizini (özellikle birim testlerinde geçici dizin kullanmak için).
  static Directory? customCacheDirectory;

  /// Verilen DOCX / belge dosyasının dönüştürülmüş PDF önbelleğini döndürür.
  ///
  /// Önbellekte geçerli bir PDF varsa yeniden dönüştürme yapmaz, doğrudan o dosyayı
  /// döndürür. Önbellek yoksa arka planda (Isolate) dönüştürme gerçekleştirip
  /// önbelleğe kaydeder.
  static Future<File> getOrConvertToPdf(String sourceFilePath) async {
    final sourceFile = File(sourceFilePath);
    if (!sourceFile.existsSync()) {
      throw FileSystemException('Kaynak belge dosyası bulunamadı', sourceFilePath);
    }

    final length = sourceFile.lengthSync();
    if (length == 0) {
      throw const FormatException('Belge dosyası boş (0 bayt)');
    }

    final stat = sourceFile.statSync();
    final cacheDir = await _getCacheDirectory();
    final cacheFileName = _generateCacheFileName(
      sourceFilePath,
      length,
      stat.modified.millisecondsSinceEpoch,
    );
    final cachedPdfFile = File(p.join(cacheDir.path, cacheFileName));

    // 1. Önbellek kontrolü
    if (cachedPdfFile.existsSync() && cachedPdfFile.lengthSync() > 0) {
      if (_isValidPdfFile(cachedPdfFile)) {
        return cachedPdfFile;
      } else {
        try {
          cachedPdfFile.deleteSync();
        } catch (_) {}
      }
    }

    // 2. Dönüştürme: Test ortamında FakeAsync isolate tıkanmasını önlemek için
    // doğrudan çalıştır, normal çalışma ortamında ise UI akıcılığını korumak için
    // arka plan Isolate'i kullan.
    final bool isTestMode = Platform.environment.containsKey('FLUTTER_TEST');
    final Uint8List pdfBytes;
    if (isTestMode) {
      pdfBytes = await _convertDocumentToPdfBytes(sourceFilePath);
    } else {
      pdfBytes = await Isolate.run(() async {
        return _convertDocumentToPdfBytes(sourceFilePath);
      });
    }

    if (pdfBytes.isEmpty || !_isValidPdfBytes(pdfBytes)) {
      throw const FormatException('Oluşturulan PDF verisi geçersiz');
    }

    // 3. Önbelleğe yazma (önce geçici dosyaya, sonra taşıma ile atomik kayıt)
    final tempTarget = File('${cachedPdfFile.path}.tmp');
    await tempTarget.writeAsBytes(pdfBytes, flush: true);
    if (cachedPdfFile.existsSync()) {
      try {
        cachedPdfFile.deleteSync();
      } catch (_) {}
    }
    await tempTarget.rename(cachedPdfFile.path);

    return cachedPdfFile;
  }

  /// Doğrudan dönüştürme işlemi (Isolate içinde çalışabilir).
  static Future<Uint8List> _convertDocumentToPdfBytes(String filePath) async {
    // 1. Katman: docx_creator'ın yerleşik OpenXML okuyucusu ve PDF aktarıcısı.
    // Başlıklar, tablolar, kenarlıklar, resimler, sayfa boyutları ve biçimlendirmeyi korur.
    try {
      final bytes = await PdfExporter.convertDocxFileToPdfBytes(filePath);
      if (bytes.isNotEmpty && _isValidPdfBytes(bytes)) {
        return bytes;
      }
    } catch (_) {
      // OpenXML ayrıştırma başarısız olursa (ör. eski .doc, .rtf veya standart dışı docx),
      // 2. Katmana geç.
    }

    // 2. Katman: Yedek metin ve tablo hiyerarşisi çıkarımı üzerinden PDF oluşturma.
    final rawBytes = File(filePath).readAsBytesSync();
    final fallbackDoc = DocxParser.parseBytes(rawBytes);

    if (fallbackDoc.blocks.isEmpty) {
      throw const FormatException(
        'Belge içeriği okunamadı veya şifreli/desteklenmeyen bir biçimde.',
      );
    }

    final builtDoc = _buildDocxFromBlocks(fallbackDoc.blocks);
    final pdfBytes = PdfExporter().exportToBytes(builtDoc);

    if (pdfBytes.isEmpty || !_isValidPdfBytes(pdfBytes)) {
      throw const FormatException('Belgeden geçerli bir PDF üretilemedi.');
    }

    return pdfBytes;
  }

  /// Ayrıştırılmış blokları docx_creator AST formatına uyarlar.
  static DocxBuiltDocument _buildDocxFromBlocks(List<DocxBlock> blocks) {
    final builder = docx();
    var hasContent = false;

    for (final block in blocks) {
      switch (block) {
        case DocxParagraphBlock(:final paragraph):
          final text = paragraph.plainText.trim();
          if (text.isNotEmpty) {
            hasContent = true;
            switch (paragraph.type) {
              case DocxBlockType.title:
              case DocxBlockType.heading1:
                builder.h1(text);
                break;
              case DocxBlockType.subtitle:
              case DocxBlockType.heading2:
                builder.heading2(text);
                break;
              case DocxBlockType.heading3:
                builder.heading3(text);
                break;
              case DocxBlockType.bulletItem:
                builder.p('• $text');
                break;
              case DocxBlockType.numberedItem:
                builder.p('1. $text');
                break;
              case DocxBlockType.paragraph:
                builder.p(text);
                break;
            }
          }
        case DocxTableBlock(:final table):
          final rows = <List<String>>[];
          for (final row in table.rows) {
            final rowCells = <String>[];
            for (final cell in row.cells) {
              rowCells.add(cell.paragraphs.map((p) => p.plainText).join('\n'));
            }
            if (rowCells.isNotEmpty) {
              rows.add(rowCells);
            }
          }
          if (rows.isNotEmpty) {
            hasContent = true;
            builder.table(rows);
          }
      }
    }

    if (!hasContent) {
      builder.p(' ');
    }

    return builder.build();
  }

  static bool _isValidPdfFile(File file) {
    try {
      if (file.lengthSync() < 4) return false;
      final raf = file.openSync(mode: FileMode.read);
      final header = raf.readSync(4);
      raf.closeSync();
      return _isPdfMagic(header);
    } catch (_) {
      return false;
    }
  }

  static bool _isValidPdfBytes(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return _isPdfMagic(bytes);
  }

  static bool _isPdfMagic(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46; // F
  }

  static Future<Directory> _getCacheDirectory() async {
    Directory baseDir;
    if (customCacheDirectory != null) {
      baseDir = customCacheDirectory!;
    } else {
      try {
        baseDir = await getTemporaryDirectory();
      } catch (_) {
        baseDir = Directory.systemTemp;
      }
    }
    final cacheDir = Directory(p.join(baseDir.path, cacheDirectoryName));
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
    return cacheDir;
  }

  static String _generateCacheFileName(
    String filePath,
    int length,
    int modifiedMs,
  ) {
    var hash = 0xcbf29ce484222325;
    final input = '$filePath:$length:$modifiedMs';
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    final rawBaseName = p.basenameWithoutExtension(filePath);
    final sanitizedBase =
        rawBaseName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_').trim();
    final prefix = sanitizedBase.isEmpty ? 'doc' : sanitizedBase;
    return '${prefix}_${hash.toRadixString(16)}.pdf';
  }

  /// Önbelleğe alınmış tüm PDF dosyalarını temizler.
  static Future<void> clearCache() async {
    try {
      final cacheDir = await _getCacheDirectory();
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
