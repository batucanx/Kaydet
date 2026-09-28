import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xml/xml.dart';

import '../../../data/database/app_database.dart';
import '../../core/actions/attachment_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import 'ods_parser.dart';
import 'xls_parser.dart';

// ----------------------------------------------------------- Veri Modelleri

class SpreadsheetCell {
  const SpreadsheetCell({required this.value, this.isNumeric = false});

  final String value;
  final bool isNumeric;
}

class SpreadsheetSheet {
  const SpreadsheetSheet({
    required this.name,
    required this.rows,
    required this.columnCount,
  });

  final String name;
  final List<List<SpreadsheetCell>> rows;
  final int columnCount;

  bool get isEmpty => rows.isEmpty;
}

class SpreadsheetBook {
  const SpreadsheetBook({required this.sheets});
  final List<SpreadsheetSheet> sheets;

  bool get isEmpty => sheets.isEmpty || sheets.every((s) => s.isEmpty);
}

// ----------------------------------------------------------- Ayrıştırıcı

/// Excel (.xlsx) ve CSV/TSV e-tablolarını ayrıştırarak satır/sütun
/// ızgarası olarak modelleyen hafif e-tablo ayrıştırıcısı.
class SpreadsheetParser {
  const SpreadsheetParser._();

  static Future<SpreadsheetBook> parseFile(String filePath) async {
    final file = File(filePath);
    final bytes = file.readAsBytesSync();
    final lower = filePath.toLowerCase();

    if (lower.endsWith('.csv') || lower.endsWith('.tsv')) {
      return parseCsvBytes(bytes, isTsv: lower.endsWith('.tsv'));
    }

    // Biçim UZANTIYA değil BAYTLARA göre seçilir (bkz. docx_viewer.dart'taki
    // aynı yaklaşım): sunucudan yanlış/eksik uzantıyla gelen ekler bile doğru
    // ayrıştırıcıya düşer, ".xls" uzantılı ama aslında .xlsx olan (ya da
    // tam tersi) nadir dosyalar bile doğru okunur.
    if (bytes.length >= 8 &&
        bytes[0] == 0xD0 &&
        bytes[1] == 0xCF &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xE0) {
      // Eski (ikili) Excel 97-2003 (.xls) — OLE2 Compound File imzası.
      return XlsParser.parse(bytes);
    }

    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (_looksLikeOdf(archive)) {
        // OpenDocument e-tablo (.ods).
        return OdsParser.parse(archive);
      }
      return _parseXlsxArchive(archive);
    }

    // Bilinen bir imza yok — yine de xlsx olarak denenir; başarısız olursa
    // hata, çağıran tarafta (bkz. `SpreadsheetPreviewWidget`) zaten "e-tablo
    // önizlemesi yüklenemedi" olarak zarifçe gösterilir.
    return parseXlsxBytes(bytes);
  }

  /// [archive] bir ODF (.ods) belgesi gibi mi görünüyor? Önce kanonik
  /// `mimetype` girdisine bakılır; yoksa `content.xml` VARLIĞI + OOXML'e
  /// özgü `xl/workbook.xml` YOKLUĞU ile ayırt edilir.
  static bool _looksLikeOdf(Archive archive) {
    final mimetypeFile = archive.findFile('mimetype');
    if (mimetypeFile != null) {
      final mime = utf8
          .decode(mimetypeFile.content as List<int>, allowMalformed: true)
          .trim();
      if (mime.startsWith('application/vnd.oasis.opendocument.')) return true;
      if (mime.isNotEmpty) return false;
    }
    return archive.findFile('content.xml') != null &&
        archive.findFile('xl/workbook.xml') == null;
  }

  /// Bayt dizisinden `.xlsx` (OpenXML ZIP) çalışma kitabını ayrıştırır.
  static SpreadsheetBook parseXlsxBytes(List<int> bytes) {
    return _parseXlsxArchive(ZipDecoder().decodeBytes(bytes));
  }

  static SpreadsheetBook _parseXlsxArchive(Archive archive) {
    final filesMap = <String, ArchiveFile>{};
    for (final f in archive.files) {
      filesMap[f.name.replaceAll('\\', '/')] = f;
    }

    // 1. Shared Strings tablosunu oku (metin hücreleri burada saklanır)
    final sharedStrings = <String>[];
    final sstFile = filesMap['xl/sharedStrings.xml'];
    if (sstFile != null) {
      final sstXml = utf8.decode(
        sstFile.content as List<int>,
        allowMalformed: true,
      );
      final sstDoc = XmlDocument.parse(sstXml);
      for (final si in sstDoc.findAllElements('si')) {
        final buffer = StringBuffer();
        for (final t in si.findAllElements('t')) {
          buffer.write(t.innerText);
        }
        sharedStrings.add(buffer.toString());
      }
    }

    // 2. Çalışma kitabı ilişkilerini oku (rId -> dosya adı)
    final relsMap = <String, String>{};
    final relsFile = filesMap['xl/_rels/workbook.xml.rels'];
    if (relsFile != null) {
      final relsXml = utf8.decode(
        relsFile.content as List<int>,
        allowMalformed: true,
      );
      final relsDoc = XmlDocument.parse(relsXml);
      for (final rel in relsDoc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null && target != null) {
          // 'worksheets/sheet1.xml' -> 'xl/worksheets/sheet1.xml'
          final fullTarget = target.startsWith('xl/')
              ? target
              : (target.startsWith('/') ? target.substring(1) : 'xl/$target');
          relsMap[id] = fullTarget;
        }
      }
    }

    // 3. Çalışma kitabı sayfa listesini oku
    final sheetMetas = <({String name, String filePath})>[];
    final wbFile = filesMap['xl/workbook.xml'];
    if (wbFile != null) {
      final wbXml = utf8.decode(
        wbFile.content as List<int>,
        allowMalformed: true,
      );
      final wbDoc = XmlDocument.parse(wbXml);
      for (final s in wbDoc.findAllElements('sheet')) {
        final name = s.getAttribute('name') ?? 'Sayfa';
        final rId = s.getAttribute('r:id') ?? s.getAttribute('id');
        final path = rId != null ? relsMap[rId] : null;
        if (path != null && filesMap.containsKey(path)) {
          sheetMetas.add((name: name, filePath: path));
        }
      }
    }

    // Eğer workbook.xml'den çıkmadıysa doğrudan xl/worksheets altındaki dosyaları al
    if (sheetMetas.isEmpty) {
      var sheetIdx = 1;
      for (final path in filesMap.keys) {
        if (path.startsWith('xl/worksheets/sheet') && path.endsWith('.xml')) {
          sheetMetas.add((name: 'Sayfa $sheetIdx', filePath: path));
          sheetIdx++;
        }
      }
    }

    if (sheetMetas.isEmpty) {
      throw const FormatException('Çalışma kitabında sayfa bulunamadı.');
    }

    // 4. Her sayfayı ayrıştır
    final sheets = <SpreadsheetSheet>[];
    for (final meta in sheetMetas) {
      final sheetFile = filesMap[meta.filePath];
      if (sheetFile == null) continue;

      final sheetXml = utf8.decode(
        sheetFile.content as List<int>,
        allowMalformed: true,
      );
      final sheetDoc = XmlDocument.parse(sheetXml);
      final sheet = _parseSheetXml(meta.name, sheetDoc, sharedStrings);
      sheets.add(sheet);
    }

    return SpreadsheetBook(sheets: sheets);
  }

  static SpreadsheetSheet _parseSheetXml(
    String sheetName,
    XmlDocument sheetDoc,
    List<String> sharedStrings,
  ) {
    // Hücreleri koordinatlarına göre geçici haritaya topla: rowIdx -> (colIdx -> cell)
    final gridMap = <int, Map<int, SpreadsheetCell>>{};
    var maxCol = 0;
    var maxRow = 0;

    for (final rowElem in sheetDoc.findAllElements('row')) {
      final rowAttr = rowElem.getAttribute('r');
      var rowIdx = (rowAttr != null ? int.tryParse(rowAttr) : null);
      if (rowIdx != null && rowIdx > 0) {
        rowIdx = rowIdx - 1;
      } else {
        rowIdx = maxRow;
      }

      var currentCol = 0;
      for (final c in rowElem.findElements('c')) {
        final ref = c.getAttribute('r');
        final colIdx = ref != null ? _colIndexFromRef(ref) : currentCol;
        currentCol = colIdx + 1;

        final t = c.getAttribute('t');
        String val = '';
        bool isNum = false;

        if (t == 's') {
          // Shared string indeksi
          final vElem = c.findElements('v').firstOrNull;
          final sIdx = vElem != null ? int.tryParse(vElem.innerText) : null;
          if (sIdx != null && sIdx >= 0 && sIdx < sharedStrings.length) {
            val = sharedStrings[sIdx];
          }
        } else if (t == 'inlineStr') {
          final isElem = c.findElements('is').firstOrNull;
          val = isElem?.findElements('t').map((e) => e.innerText).join() ?? '';
        } else if (t == 'b') {
          final vElem = c.findElements('v').firstOrNull;
          val = vElem?.innerText == '1' ? 'DOĞRU' : 'YANLIŞ';
        } else {
          // Sayısal değer veya formül sonucu
          final vElem = c.findElements('v').firstOrNull;
          val = vElem?.innerText ?? '';
          if (val.isNotEmpty && double.tryParse(val) != null) {
            isNum = true;
            val = _formatNumericString(val);
          }
        }

        if (val.isNotEmpty) {
          gridMap.putIfAbsent(rowIdx, () => {})[colIdx] = SpreadsheetCell(
            value: val,
            isNumeric: isNum,
          );
          if (colIdx >= maxCol) maxCol = colIdx + 1;
          if (rowIdx >= maxRow) maxRow = rowIdx + 1;
        }
      }
    }

    if (maxRow == 0 && maxCol == 0) {
      return SpreadsheetSheet(name: sheetName, rows: const [], columnCount: 0);
    }

    // 2B matrise çevir
    final rows = <List<SpreadsheetCell>>[];
    for (var r = 0; r < maxRow; r++) {
      final rowMap = gridMap[r] ?? const <int, SpreadsheetCell>{};
      final rowCells = <SpreadsheetCell>[];
      for (var c = 0; c < maxCol; c++) {
        rowCells.add(rowMap[c] ?? const SpreadsheetCell(value: ''));
      }
      rows.add(rowCells);
    }

    return SpreadsheetSheet(name: sheetName, rows: rows, columnCount: maxCol);
  }

  /// CSV veya TSV içeriğini ayrıştırır.
  static SpreadsheetBook parseCsvBytes(List<int> bytes, {bool isTsv = false}) {
    final rawText = utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(rawText);
    if (lines.isEmpty) {
      return const SpreadsheetBook(sheets: []);
    }

    // Ayırıcı karakteri belirle
    String sep = isTsv ? '\t' : ',';
    if (!isTsv && lines.isNotEmpty) {
      final first = lines.first;
      final semiCount = ';'.allMatches(first).length;
      final commaCount = ','.allMatches(first).length;
      final tabCount = '\t'.allMatches(first).length;
      if (semiCount > commaCount && semiCount > tabCount) {
        sep = ';';
      } else if (tabCount > commaCount && tabCount > semiCount) {
        sep = '\t';
      }
    }

    final rows = <List<SpreadsheetCell>>[];
    var maxCol = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final parts = _parseCsvLine(line, sep);
      final cells = parts.map((p) {
        final trimmed = p.trim();
        final isNum = double.tryParse(trimmed) != null;
        return SpreadsheetCell(value: trimmed, isNumeric: isNum);
      }).toList();

      if (cells.length > maxCol) maxCol = cells.length;
      rows.add(cells);
    }

    // Satır uzunluklarını eşitle
    for (var i = 0; i < rows.length; i++) {
      while (rows[i].length < maxCol) {
        rows[i].add(const SpreadsheetCell(value: ''));
      }
    }

    return SpreadsheetBook(
      sheets: [
        SpreadsheetSheet(name: 'Veri Tablosu', rows: rows, columnCount: maxCol),
      ],
    );
  }

  static List<String> _parseCsvLine(String line, String sep) {
    final result = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++; // Çift tırnak kaçışını atla
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == sep && !inQuotes) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    result.add(buffer.toString());
    return result;
  }

  static int _colIndexFromRef(String ref) {
    var col = 0;
    for (var i = 0; i < ref.length; i++) {
      final code = ref.codeUnitAt(i);
      if (code >= 65 && code <= 90) {
        col = col * 26 + (code - 64);
      } else if (code >= 97 && code <= 122) {
        col = col * 26 + (code - 96);
      } else {
        break;
      }
    }
    return col > 0 ? col - 1 : 0;
  }

  static String _formatNumericString(String s) {
    if (s.endsWith('.0')) {
      return s.substring(0, s.length - 2);
    }
    return s;
  }
}

// ----------------------------------------------------------- Önizleme Widget'ı

/// Excel ve CSV belgelerini Outlook/Gmail kalitesinde 2B ızgara, sayfa sekmeleri
/// ile ekranda önizleyen widget.
class SpreadsheetPreviewWidget extends StatefulWidget {
  const SpreadsheetPreviewWidget({
    super.key,
    required this.path,
    required this.attachment,
  });

  final String path;
  final AttachmentRow attachment;

  @override
  State<SpreadsheetPreviewWidget> createState() =>
      _SpreadsheetPreviewWidgetState();
}

class _SpreadsheetPreviewWidgetState extends State<SpreadsheetPreviewWidget> {
  late Future<SpreadsheetBook> _future;
  int _selectedSheetIndex = 0;
  String? _selectedCellValue;

  @override
  void initState() {
    super.initState();
    _future = SpreadsheetParser.parseFile(widget.path);
  }

  @override
  void didUpdateWidget(covariant SpreadsheetPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _future = SpreadsheetParser.parseFile(widget.path);
      _selectedSheetIndex = 0;
      _selectedCellValue = null;
    }
  }

  static String _columnLetter(int index) {
    var num = index + 1;
    var letter = '';
    while (num > 0) {
      final mod = (num - 1) % 26;
      letter = String.fromCharCode(65 + mod) + letter;
      num = (num - mod) ~/ 26;
    }
    return letter;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return FutureBuilder<SpreadsheetBook>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: Space.md),
                Text(
                  'E-tablo yükleniyor…',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
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
                    LucideIcons.fileSpreadsheet,
                    size: 48,
                    color: t.textSecondary,
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'E-tablo önizlemesi yüklenemedi',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Dosya biçimi bozuk olabilir veya şifreli bir e-tablo olabilir.',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: t.textSecondary),
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

        final book = snapshot.data!;
        final currentSheet = book.sheets.length > _selectedSheetIndex
            ? book.sheets[_selectedSheetIndex]
            : book.sheets.first;

        return Column(
          children: [

            // Seçili hücre çubuğu (Excel Formül/Değer Çubuğu benzeri)
            if (_selectedCellValue != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.xs,
                ),
                decoration: BoxDecoration(
                  color: t.surfaceElevated,
                  border: Border(bottom: BorderSide(color: t.divider)),
                ),
                child: Row(
                  children: [
                    Text(
                      'Hücre:',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: t.textTertiary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: SelectableText(
                        _selectedCellValue!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: t.textPrimary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(LucideIcons.x, size: 14),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          setState(() => _selectedCellValue = null),
                    ),
                  ],
                ),
              ),

            // Ana Izgara (2B Kaydırılabilir Tablo)
            Expanded(
              child: Container(
                color: t.surface,
                child: currentSheet.isEmpty
                    ? Center(
                        child: Text(
                          'Bu sayfada veri bulunmuyor.',
                          style: TextStyle(color: t.textSecondary),
                        ),
                      )
                    : _buildGrid(context, currentSheet),
              ),
            ),

            // Birden fazla sayfa varsa sayfa sekme çubuğu
            if (book.sheets.length > 1)
              Container(
                height: 42,
                decoration: BoxDecoration(
                  color: t.surfaceElevated,
                  border: Border(top: BorderSide(color: t.divider)),
                ),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: Space.xs,
                  ),
                  itemCount: book.sheets.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: Space.xs),
                  itemBuilder: (context, idx) {
                    final isSelected = idx == _selectedSheetIndex;
                    return InkWell(
                      onTap: () => setState(() {
                        _selectedSheetIndex = idx;
                        _selectedCellValue = null;
                      }),
                      borderRadius: BorderRadius.circular(Radii.xs),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.md,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected ? t.surface : Colors.transparent,
                          borderRadius: BorderRadius.circular(Radii.xs),
                          border: isSelected
                              ? Border.all(color: t.divider)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          book.sheets[idx].name,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: isSelected ? t.accent : t.textSecondary,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context, SpreadsheetSheet sheet) {
    final t = context.tokens;
    const colHeaderHeight = 28.0;
    const rowHeaderWidth = 44.0;
    const cellWidth = 110.0;
    const cellHeight = 32.0;

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Başlık Satırı (Köşe + A, B, C...)
            Row(
              children: [
                Container(
                  width: rowHeaderWidth,
                  height: colHeaderHeight,
                  decoration: BoxDecoration(
                    color: t.surfaceElevated,
                    border: Border.all(color: t.divider, width: 0.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '#',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: t.textTertiary,
                    ),
                  ),
                ),
                for (var c = 0; c < sheet.columnCount; c++)
                  Container(
                    width: cellWidth,
                    height: colHeaderHeight,
                    decoration: BoxDecoration(
                      color: t.surfaceElevated,
                      border: Border.all(color: t.divider, width: 0.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _columnLetter(c),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: t.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),

            // Veri Satırları
            for (var r = 0; r < sheet.rows.length; r++)
              Row(
                children: [
                  // Satır Numarası (1, 2, 3...)
                  Container(
                    width: rowHeaderWidth,
                    height: cellHeight,
                    decoration: BoxDecoration(
                      color: t.surfaceElevated,
                      border: Border.all(color: t.divider, width: 0.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${r + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        color: t.textTertiary,
                        fontWeight: FontWeight.w600,
                        fontVariations: AppText.semibold,
                      ),
                    ),
                  ),

                  // Satırın Hücreleri
                  for (var c = 0; c < sheet.columnCount; c++)
                    _buildCell(
                      context,
                      sheet.rows[r][c],
                      r: r,
                      c: c,
                      width: cellWidth,
                      height: cellHeight,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    SpreadsheetCell cell, {
    required int r,
    required int c,
    required double width,
    required double height,
  }) {
    final t = context.tokens;
    final isAlternate = r % 2 == 1;

    return InkWell(
      onTap: () {
        if (cell.value.isNotEmpty) {
          setState(() => _selectedCellValue = cell.value);
        }
      },
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        decoration: BoxDecoration(
          color: isAlternate
              ? t.surfaceElevated.withValues(alpha: 0.4)
              : t.surface,
          border: Border.all(color: t.divider, width: 0.5),
        ),
        alignment: cell.isNumeric
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Text(
          cell.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: t.textPrimary,
            fontFamily: cell.isNumeric ? 'monospace' : null,
          ),
        ),
      ),
    );
  }
}
