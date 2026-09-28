import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'spreadsheet_viewer.dart' show SpreadsheetBook, SpreadsheetCell, SpreadsheetSheet;

/// OpenDocument e-tablo (.ods — LibreOffice/OpenOffice Calc) biçimini okuyan
/// bağımsız ayrıştırıcı.
///
/// `.ods`, `.xlsx` gibi bir ZIP arşividir ama İÇERİĞİ OOXML DEĞİL, ODF 1.2
/// şemasıdır: tek dosya `content.xml`, kök `<office:spreadsheet>`, sayfalar
/// `<table:table>`, satırlar `<table:table-row>`, hücreler
/// `<table:table-cell>`. ODF elemanları OOXML'in aksine (`<row>`, `<c>`)
/// her zaman `table:`/`office:`/`text:` ÖN EKİYLE yazılır; bu yüzden
/// eşleştirme [_local] ile ad ön ekinden bağımsız yapılır (bkz.
/// `docx_viewer.dart`daki aynı desenli `_children`/`_descendants`).
abstract final class OdsParser {
  /// [archive], çağıran tarafça ZATEN çözülmüş bir zip arşividir (bkz.
  /// `SpreadsheetParser.parseFile` — biçim tespiti için zaten bir kez
  /// açılmıştır, burada tekrar açılmaz).
  static SpreadsheetBook parse(Archive archive) {
    final contentFile = archive.findFile('content.xml');
    if (contentFile == null) {
      throw const FormatException(
        'content.xml bulunamadı (geçerli bir ODF e-tablosu değil).',
      );
    }
    final xmlContent = utf8.decode(
      contentFile.content as List<int>,
      allowMalformed: true,
    );
    final doc = XmlDocument.parse(xmlContent);

    final spreadsheet = _descendants(doc, 'spreadsheet').firstOrNull;
    if (spreadsheet == null) {
      throw const FormatException('Çalışma kitabında e-tablo gövdesi bulunamadı.');
    }

    final sheets = <SpreadsheetSheet>[];
    for (final tableElem in _children(spreadsheet, 'table')) {
      sheets.add(_parseTable(tableElem));
    }

    if (sheets.isEmpty) {
      throw const FormatException('Çalışma kitabında sayfa bulunamadı.');
    }
    return SpreadsheetBook(sheets: sheets);
  }

  /// ODF'de boş hücreler genellikle `table:number-columns-repeated` ile TEK
  /// bir XML düğümünde yüzlerce/binlerce kez "tekrarlanır" (varsayılan boş
  /// bir tablo boyutunu doldurmak için). Bunları olduğu gibi çoğaltmak
  /// devasa, anlamsız ızgaralara yol açar — bu yüzden yalnızca GERÇEK
  /// İÇERİĞİ olan hücreler ızgaraya yazılır (bkz. [_setCell] çağrıları),
  /// boyut [gridMap]'teki en büyük dolu satır/sütuna göre kendiliğinden
  /// sınırlanır (xlsx ayrıştırıcısıyla aynı desen).
  static SpreadsheetSheet _parseTable(XmlElement tableElem) {
    final name = tableElem.getAttribute('table:name') ??
        tableElem.getAttribute('name') ??
        'Sayfa';
    final gridMap = <int, Map<int, SpreadsheetCell>>{};
    var maxCol = 0;
    var maxRow = 0;

    void setCell(int row, int col, String value, {bool isNumeric = false}) {
      if (value.isEmpty) return;
      gridMap.putIfAbsent(row, () => {})[col] =
          SpreadsheetCell(value: value, isNumeric: isNumeric);
      if (col + 1 > maxCol) maxCol = col + 1;
      if (row + 1 > maxRow) maxRow = row + 1;
    }

    // Bir satırın gerçekte kaç kez tekrarlandığını sınırsız almak yerine
    // makul bir tavana kısıtlıyoruz — gerçek belgelerde satır/sütun tekrarı
    // birkaçı geçmez, büyük değerler yalnızca "tabloyu doldur" amaçlıdır ve
    // içerikleri zaten boştur.
    const maxRepeat = 200;

    var row = 0;
    for (final rowElem in _children(tableElem, 'table-row')) {
      final rowRepeatRaw = int.tryParse(
            rowElem.getAttribute('table:number-rows-repeated') ?? '1',
          ) ??
          1;
      final rowRepeat = rowRepeatRaw.clamp(1, maxRepeat);
      final cells = _children(rowElem, 'table-cell').toList();
      final hasContent = cells.any((c) => _cellHasContent(c));

      if (hasContent) {
        for (var rr = 0; rr < rowRepeat; rr++) {
          var col = 0;
          for (final cellElem in cells) {
            final colRepeatRaw = int.tryParse(
                  cellElem.getAttribute('table:number-columns-repeated') ??
                      '1',
                ) ??
                1;
            final colRepeat = colRepeatRaw.clamp(1, maxRepeat);
            final (text, isNumeric) = _cellValue(cellElem);
            if (text.isNotEmpty) {
              for (var cc = 0; cc < colRepeat; cc++) {
                setCell(row + rr, col + cc, text, isNumeric: isNumeric);
              }
            }
            col += colRepeat;
          }
        }
      }
      row += rowRepeat;
    }

    if (maxRow == 0 && maxCol == 0) {
      return SpreadsheetSheet(name: name, rows: const [], columnCount: 0);
    }
    final rows = <List<SpreadsheetCell>>[];
    for (var r = 0; r < maxRow; r++) {
      final rowMap = gridMap[r] ?? const <int, SpreadsheetCell>{};
      rows.add([
        for (var c = 0; c < maxCol; c++)
          rowMap[c] ?? const SpreadsheetCell(value: ''),
      ]);
    }
    return SpreadsheetSheet(name: name, rows: rows, columnCount: maxCol);
  }

  static bool _cellHasContent(XmlElement cellElem) {
    if (cellElem.getAttribute('office:value') != null) return true;
    if (cellElem.getAttribute('office:boolean-value') != null) return true;
    return _children(cellElem, 'p').any((p) => p.innerText.trim().isNotEmpty);
  }

  static (String, bool) _cellValue(XmlElement cellElem) {
    final valueType = cellElem.getAttribute('office:value-type') ??
        cellElem.getAttribute('value-type');

    final paragraphs = _children(cellElem, 'p')
        .map((p) => p.innerText)
        .where((t) => t.isNotEmpty)
        .join('\n');

    if (valueType == 'boolean') {
      final raw = cellElem.getAttribute('office:boolean-value');
      return (raw == 'true' ? 'DOĞRU' : 'YANLIŞ', false);
    }

    final isNumericType = valueType == 'float' ||
        valueType == 'percentage' ||
        valueType == 'currency' ||
        valueType == 'date' ||
        valueType == 'time';

    if (paragraphs.isNotEmpty) {
      return (paragraphs, isNumericType);
    }

    // Görüntü metni (text:p) yoksa ham değere düş.
    final rawValue = cellElem.getAttribute('office:value');
    if (rawValue != null && rawValue.isNotEmpty) {
      var text = rawValue;
      if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
      return (text, true);
    }
    return ('', false);
  }

  static Iterable<XmlElement> _children(XmlElement parent, String localName) =>
      parent.children.whereType<XmlElement>().where(
            (element) => element.name.local == localName,
          );

  static Iterable<XmlElement> _descendants(XmlNode parent, String localName) =>
      parent
          .findAllElements('*')
          .where((element) => element.name.local == localName);
}
