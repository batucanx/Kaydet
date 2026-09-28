import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xml/xml.dart';

import '../../../data/database/app_database.dart';
import '../../core/actions/attachment_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import 'docx_image_resolver.dart';

/// Word (.docx, .doc) ve Zengin Metin (.rtf) belgelerini ayrıştırıp metin
/// hiyerarşisi, listeler ve tablolar olarak modelleyen güçlü ve güvenli ayrıştırıcı.
class DocxParser {
  const DocxParser._();

  /// Verilen belge dosyasını (.docx, .doc, .rtf) otomatik algılayıp ayrıştırır.
  static Future<DocxDocument> parseFile(String filePath) async {
    final file = File(filePath);
    final bytes = file.readAsBytesSync();
    return parseBytes(bytes);
  }

  /// Bayt dizisinden belge türünü (ZIP OpenXML, OLE2 Word, RTF) otomatik
  /// tespit ederek uygun motorla ayrıştırır.
  static DocxDocument parseBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      return const DocxDocument(blocks: []);
    }

    // 1. ZIP OpenXML (.docx)
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return _parseDocxZip(bytes);
    }

    // 2. Rich Text Format (.rtf)
    if (bytes.length >= 5 &&
        bytes[0] == 0x7B && // '{'
        bytes[1] == 0x5C && // '\'
        bytes[2] == 0x72 && // 'r'
        bytes[3] == 0x74 && // 't'
        bytes[4] == 0x66) {
      // 'f'
      return _parseRtf(bytes);
    }

    // 3. OLE2 Compound Document (.doc - Word 97-2003)
    if (bytes.length >= 8 &&
        bytes[0] == 0xD0 &&
        bytes[1] == 0xCF &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xE0) {
      return _parseLegacyDoc(bytes);
    }

    // 4. Genel deneme: Önce docx zip dene, sonra doc, en son metin çıkarımı yap
    try {
      return _parseDocxZip(bytes);
    } catch (_) {
      try {
        return _parseLegacyDoc(bytes);
      } catch (_) {
        return _parseTextFallback(bytes);
      }
    }
  }

  // -------------------------------------------------------- OpenXML (.docx)

  static DocxDocument _parseDocxZip(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      for (final file in archive.files) {
        if (file.name.toLowerCase() == 'word/document.xml') {
          docFile = file;
          break;
        }
      }
    }

    if (docFile == null) {
      // OOXML değil — OpenDocument Metin (.odt) olabilir; o da ZIP+XML'dir
      // ama tamamen farklı bir şema kullanır (bkz. [_parseOdtArchive]).
      if (archive.findFile('content.xml') != null) {
        return _parseOdtArchive(archive);
      }
      throw const FormatException(
        'word/document.xml bulunamadı (geçerli bir .docx değil)',
      );
    }

    // Resimleri arşivden çözümle
    final imageMap = DocxImageResolver().resolve(archive);

    // Numaralandırma / liste tanımlarını oku
    final numberingMap = _parseNumberingMap(archive);
    final listCounters = <int, int>{};

    final xmlBytes = docFile.readBytes() ?? Uint8List(0);
    final xmlContent = utf8.decode(xmlBytes, allowMalformed: true);
    final xmlDoc = XmlDocument.parse(xmlContent);

    final bodyElements = xmlDoc
        .findAllElements('*')
        .where((element) => element.name.local == 'body');
    if (bodyElements.isEmpty) {
      return DocxDocument(blocks: [], imageMap: imageMap);
    }

    final body = bodyElements.first;
    final blocks = <DocxBlock>[];

    void extractBlocks(XmlElement parent) {
      for (final child in parent.children.whereType<XmlElement>()) {
        final name = child.name.local;
        if (name == 'p') {
          final paragraph = _parseParagraph(
            child,
            imageMap,
            numberingMap: numberingMap,
            listCounters: listCounters,
          );
          if (paragraph != null) {
            blocks.add(DocxParagraphBlock(paragraph));
          }
        } else if (name == 'tbl') {
          final table = _parseTable(child, imageMap);
          if (table != null) {
            blocks.add(DocxTableBlock(table));
          }
        } else if (name == 'sdt') {
          // Structured Document Tag (Word form alanları)
          final sdtContent = _children(child, 'sdtContent').firstOrNull;
          if (sdtContent != null) {
            extractBlocks(sdtContent);
          }
        }
      }
    }

    extractBlocks(body);

    if (!_hasVisibleText(blocks)) {
      final fallback = _paragraphsFromAllText(xmlDoc);
      if (fallback.isNotEmpty) return DocxDocument(blocks: fallback, imageMap: imageMap);
    }
    return DocxDocument(blocks: blocks, imageMap: imageMap);
  }

  // ------------------------------------------------- OpenDocument (.odt)

  /// OpenDocument Metin (.odt — LibreOffice/OpenOffice Writer) belgesini
  /// ayrıştırır. `.odt` de `.docx` gibi bir ZIP arşividir ama İÇERİĞİ
  /// tamamen farklı bir şemadır (ODF 1.2): tek dosya `content.xml`, gövde
  /// `<office:text>`, paragraflar `<text:p>`/`<text:h>`, tablolar
  /// `<table:table>`. Görseller bilerek desteklenmez (kapsam dışı — eski
  /// `.doc`/RTF yolları da görsel içermez, tutarlı bir sınır).
  static DocxDocument _parseOdtArchive(Archive archive) {
    final contentFile = archive.findFile('content.xml');
    if (contentFile == null) {
      throw const FormatException(
        'content.xml bulunamadı (geçerli bir ODF belgesi değil)',
      );
    }
    final contentDoc = XmlDocument.parse(
      utf8.decode(contentFile.readBytes() ?? Uint8List(0), allowMalformed: true),
    );

    // Karakter stilleri (kalın/italik/renk/punto) hem content.xml'in kendi
    // otomatik stillerinde HEM DE ayrı styles.xml'de tanımlanabilir.
    final textStyles = <String, _OdfTextStyle>{};
    final stylesFile = archive.findFile('styles.xml');
    if (stylesFile != null) {
      try {
        textStyles.addAll(
          _parseOdfTextStyles(
            XmlDocument.parse(
              utf8.decode(stylesFile.readBytes() ?? Uint8List(0), allowMalformed: true),
            ),
          ),
        );
      } catch (_) {
        // styles.xml bozuksa yalnızca biçimlendirme kaybolur, belge yine
        // de düz metin olarak gösterilir.
      }
    }
    textStyles.addAll(_parseOdfTextStyles(contentDoc));

    final bodyElements =
        contentDoc.findAllElements('*').where((e) => e.name.local == 'body');
    if (bodyElements.isEmpty) {
      return const DocxDocument(blocks: []);
    }
    final textRoot = _children(bodyElements.first, 'text').firstOrNull ?? bodyElements.first;

    return DocxDocument(blocks: _odtBlocksFrom(textRoot, textStyles));
  }

  /// ODF `<style:style style:family="text|paragraph">` tanımlarından
  /// stil adı -> karakter özellikleri eşlemesi üretir. Yalnızca DOĞRUDAN
  /// tanımlanan özellikler okunur; `style:parent-style-name` üzerinden çok
  /// katmanlı miras zinciri İZLENMEZ (önizleme için yeterli, gerçek
  /// belgelerin ezici çoğunluğunda biçimlendirme doğrudan tanımlanır).
  static Map<String, _OdfTextStyle> _parseOdfTextStyles(XmlDocument doc) {
    final map = <String, _OdfTextStyle>{};
    for (final styleElem in _descendants(doc, 'style')) {
      final name = styleElem.getAttribute('style:name') ?? styleElem.getAttribute('name');
      if (name == null) continue;
      final props = _children(styleElem, 'text-properties').firstOrNull;
      if (props == null) continue;
      map[name] = _readOdfTextProperties(props);
    }
    return map;
  }

  static _OdfTextStyle _readOdfTextProperties(XmlElement props) {
    bool? bold;
    final weight = props.getAttribute('fo:font-weight') ?? props.getAttribute('font-weight');
    if (weight != null) {
      bold = weight.toLowerCase() == 'bold' || (int.tryParse(weight) ?? 0) >= 700;
    }

    bool? italic;
    final fontStyle = props.getAttribute('fo:font-style') ?? props.getAttribute('font-style');
    if (fontStyle != null) {
      italic = fontStyle.toLowerCase() == 'italic' || fontStyle.toLowerCase() == 'oblique';
    }

    bool? underline;
    final underlineStyle = props.getAttribute('style:text-underline-style') ??
        props.getAttribute('text-underline-style');
    if (underlineStyle != null) underline = underlineStyle != 'none';

    bool? strike;
    final strikeStyle = props.getAttribute('style:text-line-through-style') ??
        props.getAttribute('text-line-through-style');
    if (strikeStyle != null) strike = strikeStyle != 'none';

    Color? color;
    final colorHex = props.getAttribute('fo:color') ?? props.getAttribute('color');
    if (colorHex != null && colorHex.length == 7 && colorHex.startsWith('#')) {
      final intVal = int.tryParse(colorHex.substring(1), radix: 16);
      if (intVal != null) color = Color(0xFF000000 | intVal);
    }

    double? fontSize;
    final sizeStr = props.getAttribute('fo:font-size') ?? props.getAttribute('font-size');
    if (sizeStr != null && sizeStr.endsWith('pt')) {
      fontSize = double.tryParse(sizeStr.substring(0, sizeStr.length - 2));
    }

    return _OdfTextStyle(
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      color: color,
      fontSize: fontSize,
    );
  }

  static List<DocxBlock> _odtBlocksFrom(
    XmlElement container,
    Map<String, _OdfTextStyle> styles,
  ) {
    final blocks = <DocxBlock>[];

    void walk(XmlElement parent, {bool inList = false}) {
      for (final child in parent.children.whereType<XmlElement>()) {
        final name = child.name.local;
        if (name == 'p') {
          final paragraph = _odtParagraph(
            child,
            styles,
            type: inList ? DocxBlockType.bulletItem : DocxBlockType.paragraph,
            listPrefix: inList ? '•' : null,
          );
          if (paragraph != null) blocks.add(DocxParagraphBlock(paragraph));
        } else if (name == 'h') {
          final level = int.tryParse(
                child.getAttribute('text:outline-level') ??
                    child.getAttribute('outline-level') ??
                    '',
              ) ??
              1;
          final type = switch (level) {
            1 => DocxBlockType.heading1,
            2 => DocxBlockType.heading2,
            _ => DocxBlockType.heading3,
          };
          final paragraph = _odtParagraph(child, styles, type: type);
          if (paragraph != null) blocks.add(DocxParagraphBlock(paragraph));
        } else if (name == 'list') {
          for (final item in _children(child, 'list-item')) {
            walk(item, inList: true);
          }
        } else if (name == 'table') {
          final table = _odtTable(child, styles);
          if (table != null) blocks.add(DocxTableBlock(table));
        } else if (name == 'section' || name == 'list-header') {
          walk(child, inList: inList);
        }
      }
    }

    walk(container);
    return blocks;
  }

  static DocxParagraph? _odtParagraph(
    XmlElement pElem,
    Map<String, _OdfTextStyle> styles, {
    DocxBlockType type = DocxBlockType.paragraph,
    String? listPrefix,
  }) {
    final styleName = pElem.getAttribute('text:style-name') ?? pElem.getAttribute('style-name');
    final paragraphStyle = styleName != null ? styles[styleName] : null;
    final runs = _odtRuns(pElem, styles, paragraphStyle);

    if (runs.isEmpty) {
      return DocxParagraph(
        runs: const [DocxRun(text: '')],
        type: type,
        isSpacing: true,
        listPrefix: listPrefix,
      );
    }
    return DocxParagraph(runs: runs, type: type, listPrefix: listPrefix);
  }

  static List<DocxRun> _odtRuns(
    XmlElement container,
    Map<String, _OdfTextStyle> styles,
    _OdfTextStyle? inheritedStyle,
  ) {
    final runs = <DocxRun>[];

    void collect(XmlNode node, _OdfTextStyle? effectiveStyle) {
      for (final child in node.children) {
        if (child is XmlText) {
          if (child.value.isNotEmpty) {
            runs.add(_odtRunFromStyle(child.value, effectiveStyle));
          }
          continue;
        }
        if (child is! XmlElement) continue;
        final name = child.name.local;
        if (name == 'span' || name == 'a') {
          final spanStyleName =
              child.getAttribute('text:style-name') ?? child.getAttribute('style-name');
          final spanStyle = spanStyleName != null ? styles[spanStyleName] : null;
          collect(child, spanStyle ?? effectiveStyle);
        } else if (name == 'tab') {
          runs.add(_odtRunFromStyle('\t', effectiveStyle));
        } else if (name == 'line-break') {
          runs.add(_odtRunFromStyle('\n', effectiveStyle));
        } else if (name == 's') {
          final count = int.tryParse(
                child.getAttribute('text:c') ?? child.getAttribute('c') ?? '1',
              ) ??
              1;
          runs.add(_odtRunFromStyle(' ' * count.clamp(1, 200), effectiveStyle));
        }
      }
    }

    collect(container, inheritedStyle);
    return runs;
  }

  static DocxRun _odtRunFromStyle(String text, _OdfTextStyle? style) {
    return DocxRun(
      text: text,
      bold: style?.bold ?? false,
      italic: style?.italic ?? false,
      underline: style?.underline ?? false,
      strike: style?.strike ?? false,
      color: style?.color,
      fontSize: style?.fontSize,
    );
  }

  static DocxTable? _odtTable(XmlElement tableElem, Map<String, _OdfTextStyle> styles) {
    const maxRepeat = 50;
    final rows = <DocxTableRow>[];

    for (final rowElem in _children(tableElem, 'table-row')) {
      final cells = <DocxTableCell>[];
      for (final cellElem in rowElem.children.whereType<XmlElement>()) {
        final name = cellElem.name.local;
        if (name == 'covered-table-cell') {
          // Birleştirilmiş bir hücrenin kapladığı konum — boş sayılır, ama
          // sütun hizasının bozulmaması için yer tutucu olarak eklenir.
          cells.add(const DocxTableCell(paragraphs: []));
          continue;
        }
        if (name != 'table-cell') continue;

        final gridSpan = int.tryParse(
              cellElem.getAttribute('table:number-columns-spanned') ??
                  cellElem.getAttribute('number-columns-spanned') ??
                  '1',
            ) ??
            1;
        final repeat = int.tryParse(
              cellElem.getAttribute('table:number-columns-repeated') ??
                  cellElem.getAttribute('number-columns-repeated') ??
                  '1',
            ) ??
            1;

        final cellParagraphs = <DocxParagraph>[];
        for (final p in _children(cellElem, 'p')) {
          final paragraph = _odtParagraph(p, styles);
          if (paragraph != null) cellParagraphs.add(paragraph);
        }
        final cell = DocxTableCell(
          paragraphs: cellParagraphs,
          gridSpan: gridSpan.clamp(1, 50),
        );
        // Boş, ızgarayı doldurmak için tekrarlanan hücreler (bkz.
        // ods_parser.dart'taki aynı gerekçe) tek kopya eklenir; yalnızca
        // GERÇEK içeriği olan hücreler tam tekrar sayısınca çoğaltılır.
        final hasContent = cellParagraphs.any((p) => p.plainText.trim().isNotEmpty);
        final effectiveRepeat = hasContent ? repeat.clamp(1, maxRepeat) : 1;
        for (var i = 0; i < effectiveRepeat; i++) {
          cells.add(cell);
        }
      }
      if (cells.isNotEmpty) rows.add(DocxTableRow(cells: cells));
    }

    if (rows.isEmpty) return null;
    return DocxTable(rows: rows);
  }

  /// word/numbering.xml dosyasını çözümleyip numId -> biçim (decimal, bullet vb.) eşlemesi üretir.
  static Map<int, String> _parseNumberingMap(Archive archive) {
    ArchiveFile? numFile;
    for (final file in archive.files) {
      if (file.name.toLowerCase() == 'word/numbering.xml') {
        numFile = file;
        break;
      }
    }
    if (numFile == null) return const {};

    try {
      final bytes = numFile.readBytes() ?? Uint8List(0);
      final content = utf8.decode(bytes, allowMalformed: true);
      final doc = XmlDocument.parse(content);

      final abstractFmt = <int, String>{};
      for (final absElem in doc.findAllElements('*').where((e) => e.name.local == 'abstractNum')) {
        final absIdStr = absElem.getAttribute('w:abstractNumId') ?? absElem.getAttribute('abstractNumId');
        final absId = int.tryParse(absIdStr ?? '');
        if (absId == null) continue;

        final lvl = _descendants(absElem, 'lvl').firstOrNull;
        if (lvl != null) {
          final numFmt = _descendants(lvl, 'numFmt').firstOrNull;
          final fmtVal = numFmt?.getAttribute('w:val') ?? numFmt?.getAttribute('val') ?? 'bullet';
          abstractFmt[absId] = fmtVal.toLowerCase();
        }
      }

      final numFmtMap = <int, String>{};
      for (final numElem in doc.findAllElements('*').where((e) => e.name.local == 'num')) {
        final numIdStr = numElem.getAttribute('w:numId') ?? numElem.getAttribute('numId');
        final numId = int.tryParse(numIdStr ?? '');
        if (numId == null) continue;

        final absRef = _descendants(numElem, 'abstractNumId').firstOrNull;
        final absValStr = absRef?.getAttribute('w:val') ?? absRef?.getAttribute('val');
        final absId = int.tryParse(absValStr ?? '');
        if (absId != null && abstractFmt.containsKey(absId)) {
          numFmtMap[numId] = abstractFmt[absId]!;
        }
      }

      return numFmtMap;
    } catch (_) {
      return const {};
    }
  }

  static Iterable<XmlElement> _children(XmlElement parent, String localName) =>
      parent.children.whereType<XmlElement>().where(
        (element) => element.name.local == localName,
      );

  static Iterable<XmlElement> _descendants(XmlNode parent, String localName) =>
      parent
          .findAllElements('*')
          .where((element) => element.name.local == localName);

  static bool _hasVisibleText(List<DocxBlock> blocks) => blocks.any(
    (block) => switch (block) {
      DocxParagraphBlock(:final paragraph) =>
        paragraph.plainText.trim().isNotEmpty,
      DocxTableBlock(:final table) => table.rows.any(
        (row) => row.cells.any(
          (cell) => cell.paragraphs.any(
            (paragraph) => paragraph.plainText.trim().isNotEmpty,
          ),
        ),
      ),
    },
  );

  static List<DocxBlock> _paragraphsFromAllText(XmlDocument document) {
    final paragraphs = <DocxBlock>[];
    for (final paragraph in _descendants(document, 'p')) {
      final text = _descendants(
        paragraph,
        't',
      ).map((element) => element.innerText).join().trim();
      if (text.isNotEmpty) {
        paragraphs.add(
          DocxParagraphBlock(DocxParagraph(runs: [DocxRun(text: text)])),
        );
      }
    }
    return paragraphs;
  }

  static DocxParagraph? _parseParagraph(
    XmlElement pElem,
    DocxImageMap imageMap, {
    Map<int, String> numberingMap = const {},
    Map<int, int>? listCounters,
  }) {
    DocxBlockType type = DocxBlockType.paragraph;
    TextAlign alignment = TextAlign.start;
    double? spaceBefore;
    double? spaceAfter;
    double? lineSpacingMultiplier;
    double? indentLeft;
    String? listPrefix;

    final pPr = _children(pElem, 'pPr').firstOrNull;
    if (pPr != null) {
      // Stil denetimi (Heading, Title vb.)
      final pStyle = _children(pPr, 'pStyle').firstOrNull;
      if (pStyle != null) {
        final val =
            (pStyle.getAttribute('w:val') ?? pStyle.getAttribute('val') ?? '')
                .toLowerCase();
        if (val.contains('heading1') ||
            val.contains('heading 1') ||
            val.contains('baslik1') ||
            val.contains('başlık 1')) {
          type = DocxBlockType.heading1;
        } else if (val.contains('heading2') ||
            val.contains('heading 2') ||
            val.contains('baslik2') ||
            val.contains('başlık 2')) {
          type = DocxBlockType.heading2;
        } else if (val.contains('heading3') ||
            val.contains('heading 3') ||
            val.contains('baslik3') ||
            val.contains('başlık 3')) {
          type = DocxBlockType.heading3;
        } else if (val.contains('title') ||
            val.contains('baslik') ||
            val.contains('başlık')) {
          type = DocxBlockType.title;
        } else if (val.contains('subtitle') ||
            val.contains('altbaslik') ||
            val.contains('alt başlık')) {
          type = DocxBlockType.subtitle;
        }
      }

      // Hizalama
      final jc = _children(pPr, 'jc').firstOrNull;
      if (jc != null) {
        final val = (jc.getAttribute('w:val') ?? jc.getAttribute('val') ?? '')
            .toLowerCase();
        if (val == 'center') {
          alignment = TextAlign.center;
        } else if (val == 'right') {
          alignment = TextAlign.right;
        } else if (val == 'both') {
          alignment = TextAlign.justify;
        }
      }

      // Paragraf aralıkları (w:spacing)
      final spacing = _children(pPr, 'spacing').firstOrNull;
      if (spacing != null) {
        final beforeVal = spacing.getAttribute('w:before') ?? spacing.getAttribute('before');
        if (beforeVal != null) {
          final beforeTwips = double.tryParse(beforeVal);
          if (beforeTwips != null && beforeTwips > 0) {
            spaceBefore = (beforeTwips / 20.0).clamp(0.0, 72.0);
          }
        }
        final afterVal = spacing.getAttribute('w:after') ?? spacing.getAttribute('after');
        if (afterVal != null) {
          final afterTwips = double.tryParse(afterVal);
          if (afterTwips != null && afterTwips > 0) {
            spaceAfter = (afterTwips / 20.0).clamp(0.0, 72.0);
          }
        }
        final lineVal = spacing.getAttribute('w:line') ?? spacing.getAttribute('line');
        if (lineVal != null) {
          final lineTwips = double.tryParse(lineVal);
          if (lineTwips != null && lineTwips > 0) {
            lineSpacingMultiplier = (lineTwips / 240.0).clamp(0.9, 2.5);
          }
        }
      }

      // Girinti (w:ind)
      final ind = _children(pPr, 'ind').firstOrNull;
      if (ind != null) {
        final leftVal = ind.getAttribute('w:left') ?? ind.getAttribute('left');
        if (leftVal != null) {
          final leftTwips = double.tryParse(leftVal);
          if (leftTwips != null && leftTwips > 0) {
            indentLeft = (leftTwips / 20.0).clamp(0.0, 160.0);
          }
        }
      }

      // Madde işareti / liste denetimi
      final numPr = _children(pPr, 'numPr').firstOrNull;
      if (numPr != null && type == DocxBlockType.paragraph) {
        final numIdStr = _children(numPr, 'numId').firstOrNull?.getAttribute('w:val') ??
            _children(numPr, 'numId').firstOrNull?.getAttribute('val');
        final numId = int.tryParse(numIdStr ?? '');
        final fmt = numId != null ? numberingMap[numId] : null;

        if (fmt == 'decimal') {
          type = DocxBlockType.numberedItem;
          if (listCounters != null && numId != null) {
            final count = (listCounters[numId] ?? 0) + 1;
            listCounters[numId] = count;
            listPrefix = '$count.';
          } else {
            listPrefix = '1.';
          }
        } else {
          type = DocxBlockType.bulletItem;
          listPrefix = '•';
        }
      }
    }

    final runs = <DocxRun>[];
    void collectRuns(XmlElement parent) {
      for (final child in parent.children.whereType<XmlElement>()) {
        final name = child.name.local;
        if (name == 'r') {
          final run = _parseRun(child, imageMap: imageMap);
          if (run != null) runs.add(run);
        } else if (name == 'hyperlink') {
          for (final subChild in _children(child, 'r')) {
            final run = _parseRun(subChild, isLink: true, imageMap: imageMap);
            if (run != null) runs.add(run);
          }
        } else if (name == 'sdt') {
          final sdtContent = _children(child, 'sdtContent').firstOrNull;
          if (sdtContent != null) collectRuns(sdtContent);
        } else if (name == 'ins') {
          collectRuns(child);
        }
      }
    }

    collectRuns(pElem);

    if (runs.isEmpty) {
      // Boş paragraf (paragraf arası dikey boşluk)
      return DocxParagraph(
        runs: const [DocxRun(text: '')],
        isSpacing: true,
        spaceAfter: spaceAfter ?? 10.0,
      );
    }

    // Metnin başında liste veya madde işareti varsa akıllıca ayrıştır
    if (runs.isNotEmpty && runs.first.text.isNotEmpty) {
      final firstText = runs.first.text;
      final bulletMatch = RegExp(r'^[•\u2022\u25E6\u25AA\u25AB\u2013\-]\s*').firstMatch(firstText);
      if (bulletMatch != null) {
        final remainder = firstText.substring(bulletMatch.end);
        runs[0] = runs.first.copyWith(text: remainder);
        type = DocxBlockType.bulletItem;
        listPrefix ??= '•';
      } else {
        final numberMatch = RegExp(r'^(\d+[\.\)])\s+').firstMatch(firstText);
        if (numberMatch != null && type == DocxBlockType.paragraph) {
          final numStr = numberMatch.group(1)!;
          final remainder = firstText.substring(numberMatch.end);
          runs[0] = runs.first.copyWith(text: remainder);
          type = DocxBlockType.numberedItem;
          listPrefix ??= numStr;
        }
      }
    }

    return DocxParagraph(
      runs: runs,
      type: type,
      alignment: alignment,
      spaceBefore: spaceBefore,
      spaceAfter: spaceAfter,
      lineSpacingMultiplier: lineSpacingMultiplier,
      indentLeft: indentLeft,
      listPrefix: listPrefix,
    );
  }

  static bool _isPropertyTrue(XmlElement rPr, String name) {
    final elem = _children(rPr, name).firstOrNull;
    if (elem == null) return false;
    final val = (elem.getAttribute('w:val') ?? elem.getAttribute('val') ?? 'true').toLowerCase();
    return val != '0' && val != 'false' && val != 'off' && val != 'none';
  }

  static DocxRun? _parseRun(XmlElement rElem, {bool isLink = false, required DocxImageMap imageMap}) {
    bool bold = false;
    bool italic = false;
    bool underline = isLink;
    bool strike = false;
    Color? color;
    Color? bgColor;
    double? fontSize;
    final inlineImages = <DocxInlineImage>[];

    final rPr = _children(rElem, 'rPr').firstOrNull;
    if (rPr != null) {
      bold = _isPropertyTrue(rPr, 'b');
      italic = _isPropertyTrue(rPr, 'i');
      underline = underline || _isPropertyTrue(rPr, 'u');
      strike = _isPropertyTrue(rPr, 'strike');

      final colorElem = _children(rPr, 'color').firstOrNull;
      if (colorElem != null) {
        final hex =
            colorElem.getAttribute('w:val') ?? colorElem.getAttribute('val');
        if (hex != null && hex.length == 6 && hex.toLowerCase() != 'auto') {
          final intVal = int.tryParse(hex, radix: 16);
          if (intVal != null) {
            color = Color(0xFF000000 | intVal);
          }
        }
      }

      final highlightElem = _children(rPr, 'highlight').firstOrNull;
      if (highlightElem != null) {
        final val = (highlightElem.getAttribute('w:val') ?? highlightElem.getAttribute('val') ?? '').toLowerCase();
        bgColor = _mapHighlightColor(val);
      }
      final shdElem = _children(rPr, 'shd').firstOrNull;
      if (shdElem != null && bgColor == null) {
        final fill = shdElem.getAttribute('w:fill') ?? shdElem.getAttribute('fill');
        if (fill != null && fill.length == 6 && fill.toLowerCase() != 'auto') {
          final intVal = int.tryParse(fill, radix: 16);
          if (intVal != null) {
            bgColor = Color(0xFF000000 | intVal);
          }
        }
      }

      final szElem = _children(rPr, 'sz').firstOrNull ?? _children(rPr, 'szCs').firstOrNull;
      if (szElem != null) {
        final szVal =
            szElem.getAttribute('w:val') ?? szElem.getAttribute('val');
        final halfPts = double.tryParse(szVal ?? '');
        if (halfPts != null && halfPts > 0) {
          fontSize = (halfPts / 2.0).clamp(8.0, 72.0);
        }
      }
    }

    final buffer = StringBuffer();
    for (final child in rElem.children.whereType<XmlElement>()) {
      final name = child.name.local;
      if (name == 't' || name == 'instrText' || name == 'delText') {
        buffer.write(child.innerText);
      } else if (name == 'br') {
        buffer.write('\n');
      } else if (name == 'tab') {
        buffer.write('    ');
      } else if (name == 'noBreakHyphen') {
        buffer.write('-');
      } else if (name == 'sym') {
        final ch = child.getAttribute('w:char') ?? child.getAttribute('char');
        if (ch != null) {
          buffer.write(_mapSymbol(ch));
        }
      } else if (name == 'drawing' || name == 'pict') {
        for (final tElem in _descendants(child, 't')) {
          buffer.write(tElem.innerText);
        }
        inlineImages.addAll(_parseInlineImages(child, imageMap));
      }
    }

    final text = buffer.toString();
    if (text.isEmpty && inlineImages.isEmpty) return null;

    return DocxRun(
      text: text,
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      color: color,
      backgroundColor: bgColor,
      fontSize: fontSize,
      inlineImages: inlineImages,
    );
  }

  static Color? _mapHighlightColor(String val) {
    return switch (val) {
      'yellow' => const Color(0xFFFFFF00),
      'green' => const Color(0xFF00FF00),
      'cyan' => const Color(0xFF00FFFF),
      'magenta' => const Color(0xFFFF00FF),
      'blue' => const Color(0xFF0000FF),
      'red' => const Color(0xFFFF0000),
      'darkblue' => const Color(0xFF000080),
      'darkcyan' => const Color(0xFF008080),
      'darkgreen' => const Color(0xFF008000),
      'darkmagenta' => const Color(0xFF800080),
      'darkred' => const Color(0xFF800000),
      'darkyellow' => const Color(0xFF808000),
      'darkgray' || 'darkgrey' => const Color(0xFF808080),
      'lightgray' || 'lightgrey' => const Color(0xFFD3D3D3),
      'black' => const Color(0xFF000000),
      _ => null,
    };
  }

  static List<DocxInlineImage> _parseInlineImages(XmlElement parent, DocxImageMap imageMap) {
    final images = <DocxInlineImage>[];

    final drawings = parent.name.local == 'drawing'
        ? [parent]
        : _descendants(parent, 'drawing');
    for (final drawing in drawings) {
      for (final inline in _descendants(drawing, 'inline')) {
        final extent = _descendants(inline, 'extent').firstOrNull;
        int? widthEmu;
        int? heightEmu;
        if (extent != null) {
          widthEmu = int.tryParse(extent.getAttribute('cx') ?? '');
          heightEmu = int.tryParse(extent.getAttribute('cy') ?? '');
        }

        String? altText;
        final docPr = _descendants(inline, 'docPr').firstOrNull;
        if (docPr != null) {
          altText = docPr.getAttribute('descr');
        }

        for (final blip in _descendants(inline, 'blip')) {
          final relId = blip.getAttribute('r:embed') ?? blip.getAttribute('embed');
          if (relId != null && imageMap.imagesByRelId.containsKey(relId)) {
            images.add(DocxInlineImage(
              relId: relId,
              widthEmu: widthEmu ?? 0,
              heightEmu: heightEmu ?? 0,
              altText: altText,
            ));
          }
        }
      }
    }

    final picts = parent.name.local == 'pict'
        ? [parent]
        : _descendants(parent, 'pict');
    for (final pict in picts) {
      for (final shape in _descendants(pict, 'shape')) {
        int? widthEmu;
        int? heightEmu;
        final style = shape.getAttribute('style');
        if (style != null) {
          final widthMatch = RegExp(r'width:\s*([\d.]+)(px|pt|in|cm|mm|emu)').firstMatch(style);
          final heightMatch = RegExp(r'height:\s*([\d.]+)(px|pt|in|cm|mm|emu)').firstMatch(style);

          if (widthMatch != null) {
            final value = double.tryParse(widthMatch.group(1) ?? '');
            final unit = widthMatch.group(2) ?? 'px';
            widthEmu = _convertToEmu(value ?? 0, unit);
          }
          if (heightMatch != null) {
            final value = double.tryParse(heightMatch.group(1) ?? '');
            final unit = heightMatch.group(2) ?? 'px';
            heightEmu = _convertToEmu(value ?? 0, unit);
          }
        }

        String? altText = shape.getAttribute('alt') ?? shape.getAttribute('title');

        for (final imagedata in _descendants(shape, 'imagedata')) {
          final relId = imagedata.getAttribute('r:id') ?? imagedata.getAttribute('o:relid');
          if (relId != null && imageMap.imagesByRelId.containsKey(relId)) {
            images.add(DocxInlineImage(
              relId: relId,
              widthEmu: widthEmu ?? 0,
              heightEmu: heightEmu ?? 0,
              altText: altText,
            ));
          }
        }
      }
    }

    return images;
  }

  static int _convertToEmu(double value, String unit) {
    switch (unit.toLowerCase()) {
      case 'emu':
        return value.round();
      case 'px':
        return (value * 9525).round();
      case 'pt':
        return (value * 12700).round();
      case 'in':
        return (value * 914400).round();
      case 'cm':
        return (value * 360000).round();
      case 'mm':
        return (value * 36000).round();
      default:
        return (value * 9525).round();
    }
  }

  static String _mapSymbol(String hex) {
    final clean = hex.toLowerCase().replaceAll('0x', '');
    return switch (clean) {
      'f0fe' || '2611' => '☑',
      'f0a8' || '25a2' => '☐',
      'f0fc' || '2713' => '✓',
      'f0fb' || '2717' => '✗',
      'f06e' || '25a0' => '■',
      'f070' || '25a1' => '□',
      'f0a7' => '▪',
      'f0b7' => '•',
      _ => () {
        final code = int.tryParse(clean, radix: 16);
        if (code != null && code >= 0x20 && code < 0xF000) {
          return String.fromCharCode(code);
        }
        return '•';
      }(),
    };
  }

  static DocxTable? _parseTable(XmlElement tblElem, [DocxImageMap? imageMap]) {
    final effectiveImageMap =
        imageMap ?? const DocxImageMap(imagesByRelId: {}, relIdToMediaPath: {});
    final rows = <DocxTableRow>[];

    for (final tr in _children(tblElem, 'tr')) {
      final cells = <DocxTableCell>[];
      for (final tc in _children(tr, 'tc')) {
        int gridSpan = 1;
        Color? bgColor;

        final tcPr = _children(tc, 'tcPr').firstOrNull;
        if (tcPr != null) {
          final gs = _children(tcPr, 'gridSpan').firstOrNull;
          if (gs != null) {
            final val = gs.getAttribute('w:val') ?? gs.getAttribute('val');
            final parsedSpan = int.tryParse(val ?? '1');
            if (parsedSpan != null && parsedSpan > 0) {
              gridSpan = parsedSpan;
            }
          }

          final shd = _children(tcPr, 'shd').firstOrNull;
          if (shd != null) {
            final fill = shd.getAttribute('w:fill') ?? shd.getAttribute('fill');
            if (fill != null &&
                fill.length == 6 &&
                fill.toLowerCase() != 'auto') {
              final intVal = int.tryParse(fill, radix: 16);
              if (intVal != null) {
                bgColor = Color(0xFF000000 | intVal);
              }
            }
          }
        }

        final cellParagraphs = <DocxParagraph>[];
        for (final p in _children(tc, 'p')) {
          final parsedP = _parseParagraph(p, effectiveImageMap);
          if (parsedP != null) cellParagraphs.add(parsedP);
        }
        cells.add(
          DocxTableCell(
            paragraphs: cellParagraphs,
            gridSpan: gridSpan,
            backgroundColor: bgColor,
          ),
        );
      }
      if (cells.isNotEmpty) {
        rows.add(DocxTableRow(cells: cells));
      }
    }

    if (rows.isEmpty) return null;
    return DocxTable(rows: rows);
  }

  // ---------------------------------------------------- Eski Word (.doc) ve RTF

  static DocxDocument _parseLegacyDoc(List<int> bytes) {
    final text = _extractTextFromLegacyDoc(bytes);
    return _createDocumentFromPlainText(text);
  }

  static String _extractTextFromLegacyDoc(List<int> bytes) {
    final paragraphs = <String>[];
    final currentParagraph = StringBuffer();

    var i = 0;
    while (i < bytes.length - 1) {
      final b0 = bytes[i];
      final b1 = bytes[i + 1];

      // UTF-16LE kontrolü
      int? charCode;
      if (b1 == 0x00 && (b0 >= 0x20 && b0 <= 0x7E || b0 == 0x09)) {
        charCode = b0;
      } else if (b1 == 0x01) {
        // Türkçe karakterler (ı=0x0131, İ=0x0130, ğ=0x011F, Ğ=0x011E, ş=0x015F, Ş=0x015E)
        if (b0 == 0x31) charCode = 0x0131;
        if (b0 == 0x30) charCode = 0x0130;
        if (b0 == 0x1F) charCode = 0x011F;
        if (b0 == 0x1E) charCode = 0x011E;
        if (b0 == 0x5F) charCode = 0x015F;
        if (b0 == 0x5E) charCode = 0x015E;
      } else if (b1 == 0x00 &&
          (b0 == 0xE7 ||
              b0 == 0xC7 ||
              b0 == 0xF6 ||
              b0 == 0xD6 ||
              b0 == 0xFC ||
              b0 == 0xDC)) {
        charCode = b0; // ç, Ç, ö, Ö, ü, Ü
      } else if (b1 == 0x00 && (b0 == 0x0D || b0 == 0x0A)) {
        final p = currentParagraph.toString().trim();
        if (p.length >= 2) paragraphs.add(p);
        currentParagraph.clear();
        i += 2;
        continue;
      }

      if (charCode != null) {
        currentParagraph.writeCharCode(charCode);
        i += 2;
      } else {
        if (currentParagraph.length >= 4) {
          final p = currentParagraph.toString().trim();
          if (p.length >= 2) paragraphs.add(p);
        }
        currentParagraph.clear();
        i++;
      }
    }

    if (currentParagraph.length >= 4) {
      paragraphs.add(currentParagraph.toString().trim());
    }

    // UTF-16LE bulunamazsa 8-bit ASCII / UTF-8 dene
    if (paragraphs.isEmpty) {
      final sb = StringBuffer();
      for (final b in bytes) {
        if (b >= 0x20 && b <= 0x7E || b == 0x09) {
          sb.writeCharCode(b);
        } else if (b == 0x0A || b == 0x0D) {
          final line = sb.toString().trim();
          if (line.length >= 3) paragraphs.add(line);
          sb.clear();
        } else {
          if (sb.length >= 4) paragraphs.add(sb.toString().trim());
          sb.clear();
        }
      }
      if (sb.length >= 4) paragraphs.add(sb.toString().trim());
    }

    return paragraphs.join('\n\n');
  }

  static DocxDocument _parseRtf(List<int> bytes) {
    final text = _extractTextFromRtf(bytes);
    return _createDocumentFromPlainText(text);
  }

  static String _extractTextFromRtf(List<int> bytes) {
    final content = ascii.decode(bytes, allowInvalid: true);
    final sb = StringBuffer();
    var i = 0;
    var groupDepth = 0;
    var skipGroupDepth = -1;

    while (i < content.length) {
      final ch = content[i];
      if (ch == '{') {
        groupDepth++;
        if (skipGroupDepth == -1 &&
            i + 1 < content.length &&
            content[i + 1] == '\\') {
          final rest = content.substring(i);
          if (rest.startsWith(r'{\*') ||
              rest.startsWith(r'{\fonttbl') ||
              rest.startsWith(r'{\colortbl') ||
              rest.startsWith(r'{\stylesheet') ||
              rest.startsWith(r'{\info') ||
              rest.startsWith(r'{\pict')) {
            skipGroupDepth = groupDepth;
          }
        }
        i++;
        continue;
      } else if (ch == '}') {
        if (skipGroupDepth == groupDepth) {
          skipGroupDepth = -1;
        }
        groupDepth--;
        i++;
        continue;
      }

      if (skipGroupDepth != -1) {
        i++;
        continue;
      }

      if (ch == '\\') {
        i++;
        if (i >= content.length) break;
        final next = content[i];
        if (next == '\\' || next == '{' || next == '}') {
          sb.write(next);
          i++;
        } else if (next == "'") {
          i++;
          if (i + 1 < content.length) {
            final hex = content.substring(i, i + 2);
            final byte = int.tryParse(hex, radix: 16);
            if (byte != null) {
              sb.write(_decodeCp1254Byte(byte));
            }
            i += 2;
          }
        } else if (next == '~') {
          sb.write(' ');
          i++;
        } else {
          final wordBuf = StringBuffer();
          while (i < content.length &&
              RegExp(r'[a-zA-Z]').hasMatch(content[i])) {
            wordBuf.write(content[i]);
            i++;
          }
          final word = wordBuf.toString();
          final numBuf = StringBuffer();
          if (i < content.length &&
              (content[i] == '-' || RegExp(r'[0-9]').hasMatch(content[i]))) {
            numBuf.write(content[i]);
            i++;
            while (i < content.length &&
                RegExp(r'[0-9]').hasMatch(content[i])) {
              numBuf.write(content[i]);
              i++;
            }
          }
          final arg = int.tryParse(numBuf.toString());
          if (i < content.length && content[i] == ' ') {
            i++;
          }

          if (word == 'par' || word == 'line') {
            sb.write('\n');
          } else if (word == 'tab') {
            sb.write('    ');
          } else if (word == 'u' && arg != null) {
            final code = arg < 0 ? arg + 65536 : arg;
            sb.writeCharCode(code);
            if (i < content.length && content[i] == '?') {
              i++;
            }
          }
        }
      } else if (ch == '\r' || ch == '\n') {
        i++;
      } else {
        sb.write(ch);
        i++;
      }
    }

    return sb.toString();
  }

  static String _decodeCp1254Byte(int byte) {
    return switch (byte) {
      0xFD => 'ı',
      0xDD => 'İ',
      0xFE => 'ş',
      0xDE => 'Ş',
      0xF0 => 'ğ',
      0xD0 => 'Ğ',
      0xE7 => 'ç',
      0xC7 => 'Ç',
      0xF6 => 'ö',
      0xD6 => 'Ö',
      0xFC => 'ü',
      0xDC => 'Ü',
      _ => byte >= 0x20 && byte <= 0x7E ? String.fromCharCode(byte) : ' ',
    };
  }

  static DocxDocument _parseTextFallback(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      text = latin1.decode(bytes);
    }
    return _createDocumentFromPlainText(text);
  }

  static DocxDocument _createDocumentFromPlainText(String text) {
    final lines = text.split('\n');
    final blocks = <DocxBlock>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        blocks.add(
          const DocxParagraphBlock(
            DocxParagraph(runs: [DocxRun(text: '')], isSpacing: true),
          ),
        );
        continue;
      }

      DocxBlockType type = DocxBlockType.paragraph;
      if (line.startsWith('•') ||
          line.startsWith('-') ||
          line.startsWith('*')) {
        type = DocxBlockType.bulletItem;
      } else if (line.length < 60 &&
          (line == line.toUpperCase() &&
              RegExp(r'[A-ZÇĞİÖŞÜ]').hasMatch(line))) {
        type = DocxBlockType.heading2;
      }

      blocks.add(
        DocxParagraphBlock(
          DocxParagraph(
            runs: [DocxRun(text: line)],
            type: type,
          ),
        ),
      );
    }

    return DocxDocument(blocks: blocks);
  }
}

/// Bir ODF `<style:style>` tanımından okunan karakter özellikleri —
/// `null` alanlar "bu stil bu özelliği belirtmiyor" anlamına gelir (bkz.
/// `DocxParser._odtRunFromStyle`: belirtilmeyenler `false`/`null` sayılır,
/// tam bir miras zinciri İZLENMEZ — bkz. `_parseOdfTextStyles`in belgesi).
class _OdfTextStyle {
  const _OdfTextStyle({
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.color,
    this.fontSize,
  });

  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;
  final Color? color;
  final double? fontSize;
}

// ----------------------------------------------------------- Veri Modelleri

enum DocxBlockType {
  title,
  subtitle,
  heading1,
  heading2,
  heading3,
  paragraph,
  bulletItem,
  numberedItem,
}

class DocxRun {
  const DocxRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.backgroundColor,
    this.fontSize,
    this.inlineImages = const [],
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final Color? color;
  final Color? backgroundColor;
  final double? fontSize;
  final List<DocxInlineImage> inlineImages;

  DocxRun copyWith({
    String? text,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    List<DocxInlineImage>? inlineImages,
  }) {
    return DocxRun(
      text: text ?? this.text,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strike: strike ?? this.strike,
      color: color ?? this.color,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      fontSize: fontSize ?? this.fontSize,
      inlineImages: inlineImages ?? this.inlineImages,
    );
  }
}

class DocxInlineImage {
  const DocxInlineImage({
    required this.relId,
    required this.widthEmu,
    required this.heightEmu,
    this.altText,
  });

  final String relId;
  final int widthEmu;
  final int heightEmu;
  final String? altText;
}

class DocxParagraph {
  const DocxParagraph({
    required this.runs,
    this.type = DocxBlockType.paragraph,
    this.alignment = TextAlign.start,
    this.isSpacing = false,
    this.spaceBefore,
    this.spaceAfter,
    this.lineSpacingMultiplier,
    this.indentLeft,
    this.listPrefix,
  });

  final List<DocxRun> runs;
  final DocxBlockType type;
  final TextAlign alignment;
  final bool isSpacing;
  final double? spaceBefore;
  final double? spaceAfter;
  final double? lineSpacingMultiplier;
  final double? indentLeft;
  final String? listPrefix;

  String get plainText => runs.map((r) => r.text).join();
}

class DocxTableCell {
  const DocxTableCell({
    required this.paragraphs,
    this.gridSpan = 1,
    this.backgroundColor,
  });

  final List<DocxParagraph> paragraphs;
  final int gridSpan;
  final Color? backgroundColor;
}

class DocxTableRow {
  const DocxTableRow({required this.cells});
  final List<DocxTableCell> cells;
}

class DocxTable {
  const DocxTable({required this.rows});
  final List<DocxTableRow> rows;
}

sealed class DocxBlock {
  const DocxBlock();
}

class DocxParagraphBlock extends DocxBlock {
  const DocxParagraphBlock(this.paragraph);
  final DocxParagraph paragraph;
}

class DocxTableBlock extends DocxBlock {
  const DocxTableBlock(this.table);
  final DocxTable table;
}

class DocxDocument {
  const DocxDocument({
    required this.blocks,
    this.imageMap,
  });
  final List<DocxBlock> blocks;
  final DocxImageMap? imageMap;

  bool get isEmpty => blocks.isEmpty;
}

// ----------------------------------------------------------- Önizleme Widget'ı

/// Word belgesini (.docx, .doc, .rtf) yüksek aslına uygunlukla, akıcı
/// metin ve tablo düzeni ile Türkçe karakterleri eksiksiz ekranda önizleyen widget.
class DocxPreviewWidget extends StatefulWidget {
  const DocxPreviewWidget({
    super.key,
    required this.path,
    required this.attachment,
    this.onZoomChanged,
  });

  final String path;
  final AttachmentRow attachment;

  /// Kullanıcı belge içinde pinch/pan ile etkileşime başlayıp bitirdiğinde
  /// bildirir (`true`/`false`) — bkz. `PdfPreviewWidget.onZoomChanged`ın aynı
  /// gerekçesi: birden çok ek arasında geçiş yapan üst pager, etkileşim
  /// sürerken kendi yatay kaydırmasını kilitler.
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<DocxPreviewWidget> createState() => _DocxPreviewWidgetState();
}

class _DocxPreviewWidgetState extends State<DocxPreviewWidget>
    with SingleTickerProviderStateMixin {
  late Future<DocxDocument> _docFuture;

  /// Bkz. `PdfPreviewWidget._doubleTapZoomScale` — `_ImagePreview`in
  /// `PhotoView` çift-dokunma döngüsüyle aynı his: sığdırılmış görünüm
  /// (ölçek 1.0) ile bu hedef ölçek arasında geçiş yapar.
  static const double _doubleTapZoomScale = 2.5;

  final TransformationController _transformController =
      TransformationController();
  late final AnimationController _zoomAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<Matrix4>? _zoomAnimation;
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _docFuture = DocxParser.parseFile(widget.path);
  }

  @override
  void didUpdateWidget(covariant DocxPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _docFuture = DocxParser.parseFile(widget.path);
    }
  }

  @override
  void dispose() {
    _zoomAnimController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _handleDoubleTap() {
    final details = _doubleTapDetails;
    if (details == null) return;

    final isZoomedIn = _transformController.value.row0[0] > 1.05;
    if (isZoomedIn) {
      widget.onZoomChanged?.call(false);
      _animateZoomTo(Matrix4.identity());
      return;
    }

    final position = details.localPosition;
    final zoomed = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (_doubleTapZoomScale - 1),
        -position.dy * (_doubleTapZoomScale - 1),
        0,
        1,
      )
      ..scaleByDouble(
        _doubleTapZoomScale,
        _doubleTapZoomScale,
        _doubleTapZoomScale,
        1,
      );
    widget.onZoomChanged?.call(true);
    _animateZoomTo(zoomed);
  }

  void _animateZoomTo(Matrix4 target) {
    _zoomAnimController.reset();
    _zoomAnimation =
        Matrix4Tween(begin: _transformController.value, end: target).animate(
          CurvedAnimation(parent: _zoomAnimController, curve: Curves.easeInOut),
        )..addListener(() {
          _transformController.value = _zoomAnimation!.value;
        });
    unawaited(_zoomAnimController.forward());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return FutureBuilder<DocxDocument>(
      future: _docFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: t.accent),
                const SizedBox(height: Space.lg),
                Text(
                  'Yükleniyor…',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: t.textSecondary,
                      ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.fileWarning,
                    size: 48,
                    color: t.textSecondary,
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Belge önizlemesi yüklenemedi',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Belge biçimi bozuk veya şifreli olabilir.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: t.textSecondary,
                        ),
                  ),
                  const SizedBox(height: Space.xl),
                  FilledButton.icon(
                    onPressed: () => openAttachmentExternally(
                      context,
                      localPath: widget.path,
                      mimeType: widget.attachment.mimeType,
                    ),
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('Başka bir uygulamada aç'),
                  ),
                ],
              ),
            ),
          );
        }

        final doc = snapshot.data!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final viewportWidth = constraints.maxWidth;
            final isNarrow = viewportWidth < 600;
            final horizontalMargin = isNarrow ? Space.xs : Space.md;
            final pagePadding = isNarrow
                ? const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xl)
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 48);

            // Bkz. `PdfPreviewWidget`in `PdfViewPinch`i: tek bir
            // `InteractiveViewer` HEM yakınlaştırmayı HEM kaydırmayı (pan)
            // yönetir — resimdeki `PhotoView` ile aynı mantık. Önceden bunun
            // içine ayrıca bir `SingleChildScrollView` sarılıydı; iki ayrı
            // gesture yöneticisi (kaydırma ve pan) tek parmakla sürüklemede
            // birbiriyle çakışıp zoom/pan hissini resim ve PDF'ten farklı ve
            // tutarsız kılıyordu.
            return GestureDetector(
              onDoubleTapDown: _handleDoubleTapDown,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _transformController,
                minScale: 1.0,
                maxScale: 4.5,
                constrained: false,
                boundaryMargin: EdgeInsets.zero,
                onInteractionStart: widget.onZoomChanged == null
                    ? null
                    : (_) => widget.onZoomChanged!(true),
                onInteractionEnd: widget.onZoomChanged == null
                    ? null
                    : (_) => widget.onZoomChanged!(false),
                child: Container(
                  width: viewportWidth,
                  color: t.surfaceDeep,
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalMargin,
                    vertical: Space.md,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: Container(
                        width: double.infinity,
                        padding: pagePadding,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(Radii.sm),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final block in doc.blocks)
                                _buildBlock(context, block, doc.imageMap),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBlock(BuildContext context, DocxBlock block, DocxImageMap? imageMap) {
    return switch (block) {
      DocxParagraphBlock(:final paragraph) =>
        _buildParagraph(context, paragraph, imageMap),
      DocxTableBlock(:final table) => _buildTable(context, table, imageMap),
    };
  }

  Widget _buildParagraph(BuildContext context, DocxParagraph p, DocxImageMap? imageMap) {
    if (p.isSpacing ||
        (p.runs.length == 1 &&
            p.runs.first.text.isEmpty &&
            p.runs.first.inlineImages.isEmpty)) {
      return SizedBox(height: p.spaceAfter ?? 10.0);
    }

    if (p.type == DocxBlockType.bulletItem || p.type == DocxBlockType.numberedItem) {
      final prefix = p.listPrefix ?? (p.type == DocxBlockType.bulletItem ? '•' : '1.');
      return _buildListItem(context, p, prefix, imageMap);
    }

    return Padding(
      padding: EdgeInsets.only(
        left: p.indentLeft ?? 0.0,
        top: p.spaceBefore ?? _defaultTopSpacing(p.type),
        bottom: p.spaceAfter ?? _defaultBottomSpacing(p.type),
      ),
      child: _buildParagraphText(context, p, imageMap),
    );
  }

  Widget _buildListItem(
    BuildContext context,
    DocxParagraph p,
    String prefix,
    DocxImageMap? imageMap,
  ) {
    final indent = p.indentLeft ?? 0.0;
    return Padding(
      padding: EdgeInsets.only(
        left: indent,
        top: p.spaceBefore ?? 3.0,
        bottom: p.spaceAfter ?? 3.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22.0,
            child: Text(
              prefix,
              style: const TextStyle(
                color: Color(0xFF1E1E1E),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                fontVariations: AppText.semibold,
                height: 1.45,
              ),
            ),
          ),
          Expanded(
            child: _buildParagraphText(context, p, imageMap),
          ),
        ],
      ),
    );
  }

  Widget _buildParagraphText(
    BuildContext context,
    DocxParagraph p,
    DocxImageMap? imageMap,
  ) {
    final spans = <InlineSpan>[];

    for (final run in p.runs) {
      if (run.inlineImages.isNotEmpty && imageMap != null) {
        for (final img in run.inlineImages) {
          final imageBytes = imageMap.imagesByRelId[img.relId];
          if (imageBytes != null && imageBytes.isNotEmpty) {
            final double? width =
                img.widthEmu > 0 ? (img.widthEmu / 9525.0).clamp(16.0, 700.0) : null;
            final double? height =
                img.heightEmu > 0 ? (img.heightEmu / 9525.0).clamp(16.0, 900.0) : null;
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 2.0),
                  child: Image.memory(
                    imageBytes,
                    width: width,
                    height: height,
                    fit: BoxFit.contain,
                    semanticLabel: img.altText,
                  ),
                ),
              ),
            );
          }
        }
      }

      if (run.text.isNotEmpty) {
        Color textColor = const Color(0xFF1E1E1E);
        if (run.color != null) {
          // Açık renkli metinler beyaz kağıt üzerinde görünür olsun
          if (run.color!.computeLuminance() > 0.88) {
            textColor = const Color(0xFF1E1E1E);
          } else {
            textColor = run.color!;
          }
        }

        TextStyle style = TextStyle(
          color: textColor,
          fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
          decoration: _combineDecorations(run.underline, run.strike),
          decorationColor: textColor,
          backgroundColor: run.backgroundColor,
        );

        if (run.fontSize != null && run.fontSize! > 0) {
          style = style.copyWith(fontSize: run.fontSize);
        }

        spans.add(TextSpan(text: run.text, style: style));
      }
    }

    final baseStyle = _paragraphBaseStyle(context, p.type);
    final effectiveHeight = p.lineSpacingMultiplier ?? baseStyle.height ?? 1.45;

    return Text.rich(
      TextSpan(
        style: baseStyle.copyWith(height: effectiveHeight),
        children: spans,
      ),
      textAlign: p.alignment,
    );
  }

  TextDecoration? _combineDecorations(bool underline, bool strike) {
    if (underline && strike) {
      return TextDecoration.combine([
        TextDecoration.underline,
        TextDecoration.lineThrough,
      ]);
    }
    if (underline) return TextDecoration.underline;
    if (strike) return TextDecoration.lineThrough;
    return null;
  }

  TextStyle _paragraphBaseStyle(BuildContext context, DocxBlockType type) {
    return switch (type) {
      DocxBlockType.title => const TextStyle(
          color: Color(0xFF111827),
          fontSize: 22.0,
          fontWeight: FontWeight.bold,
          height: 1.3,
        ),
      DocxBlockType.subtitle => const TextStyle(
          color: Color(0xFF4B5563),
          fontSize: 16.0,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
      DocxBlockType.heading1 => const TextStyle(
          color: Color(0xFF111827),
          fontSize: 18.0,
          fontWeight: FontWeight.bold,
          height: 1.35,
        ),
      DocxBlockType.heading2 => const TextStyle(
          color: Color(0xFF1F2937),
          fontSize: 15.0,
          fontWeight: FontWeight.w600,
          fontVariations: AppText.semibold,
          height: 1.4,
        ),
      DocxBlockType.heading3 => const TextStyle(
          color: Color(0xFF374151),
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          fontVariations: AppText.semibold,
          height: 1.4,
        ),
      DocxBlockType.paragraph ||
      DocxBlockType.bulletItem ||
      DocxBlockType.numberedItem =>
        const TextStyle(
          color: Color(0xFF1E1E1E),
          fontSize: 13.0,
          fontWeight: FontWeight.normal,
          height: 1.45,
        ),
    };
  }

  double _defaultTopSpacing(DocxBlockType type) {
    return switch (type) {
      DocxBlockType.title => 16.0,
      DocxBlockType.subtitle => 4.0,
      DocxBlockType.heading1 => 14.0,
      DocxBlockType.heading2 => 10.0,
      DocxBlockType.heading3 => 8.0,
      DocxBlockType.paragraph ||
      DocxBlockType.bulletItem ||
      DocxBlockType.numberedItem =>
        3.0,
    };
  }

  double _defaultBottomSpacing(DocxBlockType type) {
    return switch (type) {
      DocxBlockType.title => 8.0,
      DocxBlockType.subtitle => 10.0,
      DocxBlockType.heading1 => 6.0,
      DocxBlockType.heading2 => 4.0,
      DocxBlockType.heading3 => 4.0,
      DocxBlockType.paragraph ||
      DocxBlockType.bulletItem ||
      DocxBlockType.numberedItem =>
        3.0,
    };
  }

  Widget _buildTable(
    BuildContext context,
    DocxTable table,
    DocxImageMap? imageMap,
  ) {
    const borderColor = Color(0xFFD1D5DB);
    var maxCols = 1;
    for (final row in table.rows) {
      final spans = row.cells.fold<int>(0, (sum, cell) => sum + cell.gridSpan);
      if (spans > maxCols) maxCols = spans;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = maxCols > 4
            ? (maxCols * 130.0).clamp(constraints.maxWidth, 1400.0)
            : constraints.maxWidth;

        return Container(
          margin: const EdgeInsets.symmetric(vertical: Space.md),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 1.0),
            borderRadius: BorderRadius.circular(Radii.xs),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var r = 0; r < table.rows.length; r++) ...[
                    if (r > 0)
                      Container(height: 1.0, color: borderColor),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var c = 0; c < table.rows[r].cells.length; c++) ...[
                          if (c > 0)
                            Container(width: 1.0, color: borderColor),
                          Expanded(
                            flex: table.rows[r].cells[c].gridSpan,
                            child: Container(
                              color: table.rows[r].cells[c].backgroundColor ??
                                  (r == 0 ? const Color(0xFFF9FAFB) : Colors.white),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10.0,
                                vertical: 8.0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final p in table.rows[r].cells[c].paragraphs)
                                    _buildParagraph(context, p, imageMap),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
