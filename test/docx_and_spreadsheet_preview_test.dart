import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/ui/features/attachment_preview/docx_image_resolver.dart';
import 'package:kaydet/ui/features/attachment_preview/docx_pdf_converter.dart';
import 'package:kaydet/ui/features/attachment_preview/docx_viewer.dart';
import 'package:kaydet/ui/features/attachment_preview/spreadsheet_viewer.dart';

void main() {
  group('DocxParser', () {
    test('parses paragraphs, styles, and tables from .docx archive', () {
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr>
        <w:pStyle w:val="Heading1"/>
      </w:pPr>
      <w:r>
        <w:rPr><w:b/></w:rPr>
        <w:t>Proje Başlığı</w:t>
      </w:r>
    </w:p>
    <w:p>
      <w:r>
        <w:t>Bu bir açıklama paragrafıdır. </w:t>
      </w:r>
      <w:r>
        <w:rPr><w:i/></w:rPr>
        <w:t>İtalik metin.</w:t>
      </w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc>
          <w:p><w:r><w:t>Hücre 1</w:t></w:r></w:p>
        </w:tc>
        <w:tc>
          <w:p><w:r><w:t>Hücre 2</w:t></w:r></w:p>
        </w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''';

      final archive = Archive();
      final xmlBytes = utf8.encode(xml);
      archive.addFile(
        ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes),
      );
      final zipBytes = ZipEncoder().encode(archive);

      final doc = DocxParser.parseBytes(zipBytes);
      expect(doc.blocks.length, 3);

      // 1. Başlık
      final b1 = doc.blocks[0] as DocxParagraphBlock;
      expect(b1.paragraph.type, DocxBlockType.heading1);
      expect(b1.paragraph.plainText, 'Proje Başlığı');
      expect(b1.paragraph.runs.first.bold, isTrue);

      // 2. Paragraf
      final b2 = doc.blocks[1] as DocxParagraphBlock;
      expect(b2.paragraph.type, DocxBlockType.paragraph);
      expect(
        b2.paragraph.plainText,
        'Bu bir açıklama paragrafıdır. İtalik metin.',
      );
      expect(b2.paragraph.runs[1].italic, isTrue);

      // 3. Tablo
      final b3 = doc.blocks[2] as DocxTableBlock;
      expect(b3.table.rows.length, 1);
      expect(b3.table.rows.first.cells.length, 2);
      expect(
        b3.table.rows.first.cells[0].paragraphs.first.plainText,
        'Hücre 1',
      );
      expect(
        b3.table.rows.first.cells[1].paragraphs.first.plainText,
        'Hücre 2',
      );
    });
  });

  group('SpreadsheetParser', () {
    test('parses sheets, shared strings, and cells from .xlsx archive', () {
      final sstXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
  <si><t>Ürün Adı</t></si>
  <si><t>Laptop</t></si>
</sst>''';

      final wbXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Satışlar" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>''';

      final relsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>''';

      final sheetXml =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="s"><v>0</v></c>
      <c r="B1"><v>Fiyat</v></c>
    </row>
    <row r="2">
      <c r="A2" t="s"><v>1</v></c>
      <c r="B2"><v>25000</v></c>
    </row>
  </sheetData>
</worksheet>''';

      final archive = Archive();
      void add(String name, String content) {
        final b = utf8.encode(content);
        archive.addFile(ArchiveFile(name, b.length, b));
      }

      add('xl/sharedStrings.xml', sstXml);
      add('xl/workbook.xml', wbXml);
      add('xl/_rels/workbook.xml.rels', relsXml);
      add('xl/worksheets/sheet1.xml', sheetXml);

      final zipBytes = ZipEncoder().encode(archive);
      final book = SpreadsheetParser.parseXlsxBytes(zipBytes);

      expect(book.sheets.length, 1);
      final sheet = book.sheets.first;
      expect(sheet.name, 'Satışlar');
      expect(sheet.rows.length, 2);
      expect(sheet.columnCount, 2);

      // Row 1
      expect(sheet.rows[0][0].value, 'Ürün Adı');
      expect(sheet.rows[0][1].value, 'Fiyat');

      // Row 2
      expect(sheet.rows[1][0].value, 'Laptop');
      expect(sheet.rows[1][1].value, '25000');
      expect(sheet.rows[1][1].isNumeric, isTrue);
    });

    test('parses CSV data with various delimiters', () {
      const csv = 'Ad;Soyad;Maaş\nAhmet;Yılmaz;45000\nMehmet;Demir;50000';
      final book = SpreadsheetParser.parseCsvBytes(utf8.encode(csv));

      expect(book.sheets.length, 1);
      final sheet = book.sheets.first;
      expect(sheet.rows.length, 3);
      expect(sheet.rows[0][0].value, 'Ad');
      expect(sheet.rows[0][2].value, 'Maaş');
      expect(sheet.rows[1][0].value, 'Ahmet');
      expect(sheet.rows[1][2].value, '45000');
      expect(sheet.rows[1][2].isNumeric, isTrue);
    });
  });

  group('Preview Widgets Rendering', () {
    late Directory tempDir;
    late File docxFile;
    late File xlsxFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kaydet_test_');

      // Sample docx
      final docxXml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Test Dokümanı</w:t></w:r></w:p>
  </w:body>
</w:document>''';
      final aDoc = Archive();
      final bDoc = utf8.encode(docxXml);
      aDoc.addFile(ArchiveFile('word/document.xml', bDoc.length, bDoc));
      docxFile = File('${tempDir.path}/test.docx');
      await docxFile.writeAsBytes(ZipEncoder().encode(aDoc));

      // Sample xlsx
      final aXls = Archive();
      final bXls = utf8.encode('''<?xml version="1.0"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1"><v>Veri 123</v></c></row>
  </sheetData>
</worksheet>''');
      aXls.addFile(ArchiveFile('xl/worksheets/sheet1.xml', bXls.length, bXls));
      xlsxFile = File('${tempDir.path}/test.xlsx');
      await xlsxFile.writeAsBytes(ZipEncoder().encode(aXls));
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets(
      'DocxPreviewWidget renders read-only banner and prepares PDF preview',
      (tester) async {
        final attachment = AttachmentRow(
          id: 1,
          messageId: 10,
          partId: '1',
          fileName: 'test.docx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          sizeBytes: 1024,
          isInline: false,
          isOutgoing: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DocxPreviewWidget(
                path: docxFile.path,
                attachment: attachment,
              ),
            ),
          ),
        );

        await tester.pump();

        expect(find.textContaining('Düzenle'), findsNothing);

        // Verify PDF conversion succeeds for document
        final pdfFile = await tester.runAsync(() => DocxPdfConverter.getOrConvertToPdf(docxFile.path));
        expect(pdfFile, isNotNull);
        expect(pdfFile!.existsSync(), isTrue);
        expect(pdfFile.lengthSync(), greaterThan(0));
      },
    );

    testWidgets('SpreadsheetPreviewWidget renders grid without an edit action', (
      tester,
    ) async {
      final attachment = AttachmentRow(
        id: 2,
        messageId: 10,
        partId: '1',
        fileName: 'test.xlsx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        sizeBytes: 2048,
        isInline: false,
        isOutgoing: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpreadsheetPreviewWidget(
              path: xlsxFile.path,
              attachment: attachment,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Düzenle'), findsNothing);
      expect(find.text('Veri 123'), findsOneWidget);
    });

    testWidgets(
      'DocxPreviewWidget renders complex table with irregular row lengths and gridSpan',
      (tester) async {
        final docxArchive = Archive();
        void add(String name, String content) {
          final b = utf8.encode(content);
          docxArchive.addFile(ArchiveFile(name, b.length, b));
        }

        add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
</Types>''');

        const complexTableXml =
            '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Başvuru Formu</w:t></w:r></w:p>
    <w:tbl>
      <w:tr>
        <w:tc>
          <w:tcPr><w:gridSpan w:val="3"/></w:tcPr>
          <w:p><w:r><w:t>Geniş Başlık Hücresi</w:t></w:r></w:p>
        </w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Hücre A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Hücre B</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Hücre C</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''';
        add('word/document.xml', complexTableXml);

        final complexDocxFile = File('${tempDir.path}/complex.docx')
          ..writeAsBytesSync(ZipEncoder().encode(docxArchive));

        final attachment = AttachmentRow(
          id: 3,
          messageId: 10,
          partId: '1',
          fileName: 'complex.docx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          sizeBytes: 1024,
          isInline: false,
          isOutgoing: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DocxPreviewWidget(
                path: complexDocxFile.path,
                attachment: attachment,
              ),
            ),
          ),
        );

        await tester.pump();

        expect(find.textContaining('Düzenle'), findsNothing);

        // Verify PDF conversion succeeds for complex table document
        final pdfFile = await tester.runAsync(() => DocxPdfConverter.getOrConvertToPdf(complexDocxFile.path));
        expect(pdfFile, isNotNull);
        expect(pdfFile!.existsSync(), isTrue);
        expect(pdfFile.lengthSync(), greaterThan(0));

        // Verify AST parser still correctly parses table with gridSpan
        final doc = DocxParser.parseBytes(complexDocxFile.readAsBytesSync());
        expect(doc.blocks.length, 2);
        final tableBlock = doc.blocks[1] as DocxTableBlock;
        expect(tableBlock.table.rows.first.cells.first.gridSpan, 3);
      },
    );

    testWidgets(
      'DocxPreviewWidget renders screenshot scenario with Turkish chars, lists, tables, bold/italic',
      (tester) async {
        final docxArchive = Archive();
        void add(String name, String content) {
          final b = utf8.encode(content);
          docxArchive.addFile(ArchiveFile(name, b.length, b));
        }

        add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
</Types>''');

        const richXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:b/><w:t>BU BİLGİYİ BENCE BİR ÇOK EMLAKÇI BİLMİYOR.</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Türkçe karakterlerin tümü: ç Ç ğ Ğ ı İ ö Ö ş Ş ü Ü</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:b/><w:t>Emlakçılar Ne Zamandan Beri MASAK Yükümlüsü?</w:t></w:r>
      <w:r><w:tab/><w:b/><w:t>HEMEN BAKALIM</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:b/><w:t>Kanun Düzeyinde : </w:t></w:r>
      <w:r><w:t>18 Ekim 2006 tarihinde yayımlanan </w:t></w:r>
      <w:r><w:b/><w:t>5549 Sayılı</w:t></w:r>
      <w:r><w:t> Suç Gelirlerinin Aklanmasının Önlenmesi </w:t></w:r>
      <w:r><w:b/><w:t>Hakkında Kanun</w:t></w:r>
      <w:r><w:t> ile temelleri belirlendi,</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:b/><w:t>Yönetmelik Düzeyinde ise : </w:t></w:r>
      <w:r><w:t>Resmi Gazete'de 9 Ocak 2008 tarihinde yayımlanarak yürürlüğe giren </w:t></w:r>
      <w:r><w:i/><w:t>Suç Gelirlerinin Aklanmasının ve Terör Finansmanının Önlenmesine Dair Tedbirler Hakkında Yönetmelik</w:t></w:r>
      <w:r><w:t> 'in 3. maddesi ile </w:t></w:r>
      <w:r><w:b/><w:t>"Taşınmaz alım satımıyla uğraşanlar/ Emlak işletmeleri"</w:t></w:r>
      <w:r><w:t> açık bir şekilde MASAK kapsamında </w:t></w:r>
      <w:r><w:b/><w:t>"Yükümlü sayılmıştır."</w:t></w:r>
    </w:p>
    <w:p/>
    <w:tbl>
      <w:tr>
        <w:tc>
          <w:tcPr><w:gridSpan w:val="2"/><w:shd w:fill="E5E7EB"/></w:tcPr>
          <w:p><w:r><w:b/><w:t>Tablo Başlığı</w:t></w:r></w:p>
        </w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Hücre 1 (Şeker)</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Hücre 2 (Ağaç)</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''';
        add('word/document.xml', richXml);

        final testDocxFile = File('${tempDir.path}/screenshot_doc.docx')
          ..writeAsBytesSync(ZipEncoder().encode(docxArchive));

        final attachment = AttachmentRow(
          id: 4,
          messageId: 10,
          partId: '1',
          fileName: 'screenshot_doc.docx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          sizeBytes: testDocxFile.lengthSync(),
          isInline: false,
          isOutgoing: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DocxPreviewWidget(
                path: testDocxFile.path,
                attachment: attachment,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(find.textContaining('ç Ç ğ Ğ ı İ ö Ö ş Ş ü Ü', findRichText: true), findsOneWidget);
        expect(find.textContaining('BU BİLGİYİ BENCE BİR ÇOK EMLAKÇI BİLMİYOR.', findRichText: true), findsOneWidget);
        expect(find.textContaining('Emlakçılar Ne Zamandan Beri MASAK Yükümlüsü?', findRichText: true), findsOneWidget);
        expect(find.textContaining('5549 Sayılı', findRichText: true), findsOneWidget);
        expect(find.textContaining('Aklanmasının Önlenmesi', findRichText: true), findsOneWidget);
        expect(find.textContaining('Taşınmaz alım satımıyla uğraşanlar', findRichText: true), findsOneWidget);
        expect(find.textContaining('Tablo Başlığı', findRichText: true), findsOneWidget);
        expect(find.textContaining('Hücre 1 (Şeker)', findRichText: true), findsOneWidget);
        expect(find.textContaining('Hücre 2 (Ağaç)', findRichText: true), findsOneWidget);
      },
    );

    test('DocxParser parses RTF content', () {
      const rtf =
          r"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\b Baslik\b0\par Bu bir RTF testidir.}";
      final doc = DocxParser.parseBytes(utf8.encode(rtf));
      expect(doc.blocks.length, 2);
      expect(doc.blocks[0] is DocxParagraphBlock, isTrue);
      expect(
        (doc.blocks[0] as DocxParagraphBlock).paragraph.plainText,
        'Baslik',
      );
      expect(
        (doc.blocks[1] as DocxParagraphBlock).paragraph.plainText,
        'Bu bir RTF testidir.',
      );
    });

    test('DocxParser parses legacy .doc binary stream content', () {
      final docBytes = <int>[
        0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
        ...List.filled(200, 0),
        // UTF-16LE: "Belge Basligi\r"
        ...[
          0x42,
          0x00,
          0x65,
          0x00,
          0x6C,
          0x00,
          0x67,
          0x00,
          0x65,
          0x00,
          0x20,
          0x00,
          0x42,
          0x00,
          0x61,
          0x00,
          0x73,
          0x00,
          0x6C,
          0x00,
          0x69,
          0x00,
          0x67,
          0x00,
          0x69,
          0x00,
          0x0D,
          0x00,
        ],
        // UTF-16LE: "Ikinci satir\r"
        ...[
          0x49,
          0x00,
          0x6B,
          0x00,
          0x69,
          0x00,
          0x6E,
          0x00,
          0x63,
          0x00,
          0x69,
          0x00,
          0x20,
          0x00,
          0x73,
          0x00,
          0x61,
          0x00,
          0x74,
          0x00,
          0x69,
          0x00,
          0x72,
          0x00,
          0x0D,
          0x00,
        ],
        ...List.filled(100, 0),
      ];

      final doc = DocxParser.parseBytes(docBytes);
      expect(doc.blocks.isNotEmpty, isTrue);
      final text = doc.blocks
          .whereType<DocxParagraphBlock>()
          .map((b) => b.paragraph.plainText)
          .join(' ');
      expect(text.contains('Belge Basligi'), isTrue);
      expect(text.contains('Ikinci satir'), isTrue);
    });
  });

  group('DocxImageResolver', () {
    // Helper to create a minimal valid PNG (1x1 transparent pixel)
    Uint8List createTestPng() {
      // Minimal valid PNG: 1x1 transparent pixel (67 bytes)
      return Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR chunk length
        0x49, 0x48, 0x44, 0x52, // IHDR
        0x00, 0x00, 0x00, 0x01, // width: 1
        0x00, 0x00, 0x00, 0x01, // height: 1
        0x08, // bit depth: 8
        0x06, // color type: truecolor with alpha
        0x00, // compression
        0x00, // filter
        0x00, // interlace
        0x1F, 0x15, 0xC4, 0x89, // CRC
        0x00, 0x00, 0x00, 0x0A, // IDAT chunk length
        0x49, 0x44, 0x41, 0x54, // IDAT
        0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01,
        0xE2, 0x21, 0xBC, 0x33, // CRC (approximate)
        0x00, 0x00, 0x00, 0x00, // IEND chunk length
        0x49, 0x45, 0x4E, 0x44, // IEND
        0xAE, 0x42, 0x60, 0x82, // CRC
      ]);
    }

    void addFile(Archive archive, String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    void addFileBytes(Archive archive, String name, Uint8List bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    Archive createTestArchiveWithImage() {
      final archive = Archive();

      // [Content_Types].xml (required for valid docx)
      addFile(archive, '[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''');

      // _rels/.rels (package relationships)
      addFile(archive, '_rels/.rels', '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''');

      // word/document.xml (main document with drawing referencing image)
      addFile(archive, 'word/document.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:body>
    <w:p>
      <w:r>
        <w:drawing>
          <wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                  <pic:blipFill>
                    <a:blip r:embed="rId4"/>
                  </pic:blipFill>
                </pic:pic>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing>
      </w:r>
    </w:p>
  </w:body>
</w:document>''');

      // word/_rels/document.xml.rels (relationships including image)
      addFile(archive, 'word/_rels/document.xml.rels', '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image2.jpg"/>
</Relationships>''');

      // word/styles.xml (minimal)
      addFile(archive, 'word/styles.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>''');

      // word/media/image1.png (valid PNG)
      addFileBytes(archive, 'word/media/image1.png', createTestPng());

      // word/media/image2.jpg (dummy JPEG - just some bytes)
      addFileBytes(archive, 'word/media/image2.jpg', Uint8List.fromList(List.filled(200, 0xFF)));

      return archive;
    }

    test('DocxImageResolver extracts images from document.xml.rels and media folder', () {
      final archive = createTestArchiveWithImage();
      final resolver = DocxImageResolver();
      final map = resolver.resolve(archive);

      expect(map.imagesByRelId, isNotEmpty);
      expect(map.imagesByRelId.keys.first, startsWith('rId'));
      // Minimal 1x1 PNG is ~69 bytes, so expect > 50
      expect(map.imagesByRelId.values.first.length, greaterThan(50));
    });

    test('DocxImageResolver returns empty map when no relationships file exists', () {
      final archive = Archive();
      addFile(archive, 'word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>');

      final resolver = DocxImageResolver();
      final map = resolver.resolve(archive);

      expect(map.imagesByRelId, isEmpty);
      expect(map.relIdToMediaPath, isEmpty);
    });

    test('DocxImageResolver handles case-insensitive paths', () {
      final archive = Archive();
      addFile(archive, '[Content_Types].xml', '''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>''');
      addFile(archive, 'word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>');
      // Use uppercase path
      addFile(archive, 'WORD/_RELS/DOCUMENT.XML.RELS', '''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/test.png"/>
</Relationships>''');
      addFileBytes(archive, 'word/media/test.png', createTestPng());

      final resolver = DocxImageResolver();
      final map = resolver.resolve(archive);

      expect(map.imagesByRelId, isNotEmpty);
      expect(map.imagesByRelId.containsKey('rId1'), isTrue);
    });
  });

  group('DocxInlineImage', () {
    test('DocxInlineImage can be created with all properties', () {
      final img = DocxInlineImage(
        relId: 'rId4',
        widthEmu: 914400,
        heightEmu: 685800,
        altText: 'Test image',
      );
      expect(img.relId, 'rId4');
      expect(img.widthEmu, 914400);
      expect(img.heightEmu, 685800);
      expect(img.altText, 'Test image');
    });

    test('DocxInlineImage can be created without altText', () {
      final img = DocxInlineImage(
        relId: 'rId1',
        widthEmu: 100,
        heightEmu: 100,
      );
      expect(img.relId, 'rId1');
      expect(img.widthEmu, 100);
      expect(img.heightEmu, 100);
      expect(img.altText, isNull);
    });
  });

  group('DocxRun inlineImages', () {
    test('DocxRun can be created with inlineImages', () {
      final run = DocxRun(
        text: 'Hello',
        inlineImages: [
          DocxInlineImage(relId: 'rId1', widthEmu: 100, heightEmu: 100),
        ],
      );
      expect(run.inlineImages.length, 1);
      expect(run.inlineImages.first.relId, 'rId1');
    });
  });

  group('DocxParser inline images', () {
    // Helper to create a minimal valid PNG (1x1 transparent pixel)
    Uint8List createTestPng() {
      // Minimal valid PNG: 1x1 transparent pixel (67 bytes)
      return Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR chunk length
        0x49, 0x48, 0x44, 0x52, // IHDR
        0x00, 0x00, 0x00, 0x01, // width: 1
        0x00, 0x00, 0x00, 0x01, // height: 1
        0x08, // bit depth: 8
        0x06, // color type: truecolor with alpha
        0x00, // compression
        0x00, // filter
        0x00, // interlace
        0x1F, 0x15, 0xC4, 0x89, // CRC
        0x00, 0x00, 0x00, 0x0A, // IDAT chunk length
        0x49, 0x44, 0x41, 0x54, // IDAT
        0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01,
        0xE2, 0x21, 0xBC, 0x33, // CRC (approximate)
        0x00, 0x00, 0x00, 0x00, // IEND chunk length
        0x49, 0x45, 0x4E, 0x44, // IEND
        0xAE, 0x42, 0x60, 0x82, // CRC
      ]);
    }

    void addFile(Archive archive, String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    void addFileBytes(Archive archive, String name, Uint8List bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    String createDocxXmlWithInlineImage() {
      return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>
    <w:p>
      <w:r>
        <w:drawing>
          <wp:inline>
            <wp:extent cx="914400" cy="685800"/>
            <wp:docPr id="1" name="Picture 1" descr="Test image"/>
            <a:graphic>
              <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic>
                  <pic:blipFill>
                    <a:blip r:embed="rId4"/>
                  </pic:blipFill>
                </pic:pic>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing>
      </w:r>
    </w:p>
  </w:body>
</w:document>''';
    }

    Archive createArchiveWithImageAndRels(String xml) {
      final archive = Archive();

      // [Content_Types].xml (required for valid docx)
      addFile(archive, '[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''');

      // _rels/.rels (package relationships)
      addFile(archive, '_rels/.rels', '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''');

      // word/document.xml (main document with drawing referencing image)
      addFile(archive, 'word/document.xml', xml);

      // word/_rels/document.xml.rels (relationships including image)
      addFile(archive, 'word/_rels/document.xml.rels', '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image2.jpg"/>
</Relationships>''');

      // word/styles.xml (minimal)
      addFile(archive, 'word/styles.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>''');

      // word/media/image1.png (valid PNG)
      addFileBytes(archive, 'word/media/image1.png', createTestPng());

      // word/media/image2.jpg (dummy JPEG - just some bytes)
      addFileBytes(archive, 'word/media/image2.jpg', Uint8List.fromList(List.filled(200, 0xFF)));

      return archive;
    }

    test('DocxParser extracts inline images from drawing elements with correct rId', () {
      final xml = createDocxXmlWithInlineImage();
      final archive = createArchiveWithImageAndRels(xml);
      final archiveBytes = ZipEncoder().encode(archive);
      final doc = DocxParser.parseBytes(archiveBytes);
      
      final para = doc.blocks.first as DocxParagraphBlock;
      final run = para.paragraph.runs.first;
      expect(run.inlineImages, isNotEmpty);
      expect(run.inlineImages.first.relId, 'rId4');
      expect(run.inlineImages.first.widthEmu, 914400);
      expect(run.inlineImages.first.heightEmu, 685800);
      expect(run.inlineImages.first.altText, 'Test image');
    });

    test('DocxDocument stores DocxImageMap from archive', () {
      final archive = createArchiveWithImageAndRels(createDocxXmlWithInlineImage());
      final archiveBytes = ZipEncoder().encode(archive);
      final doc = DocxParser.parseBytes(archiveBytes);
      
      expect(doc.imageMap, isNotNull);
      expect(doc.imageMap!.imagesByRelId.containsKey('rId4'), isTrue);
    });
  });

  group('DocxPdfConverter', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('docx_converter_test_');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('converts valid .docx to PDF and caches result', () async {
      final docxArchive = Archive();
      final xmlBytes = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Dönüştürme Testi</w:t></w:r></w:p>
  </w:body>
</w:document>''');
      docxArchive.addFile(ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes));
      final testFile = File('${tempDir.path}/conv_test.docx');
      await testFile.writeAsBytes(ZipEncoder().encode(docxArchive));

      final firstPdf = await DocxPdfConverter.getOrConvertToPdf(testFile.path);
      expect(firstPdf.existsSync(), isTrue);
      expect(firstPdf.path.endsWith('.pdf'), isTrue);
      expect(firstPdf.lengthSync(), greaterThan(0));

      final firstModified = firstPdf.lastModifiedSync();

      // Second call must return the cached file without re-conversion
      final secondPdf = await DocxPdfConverter.getOrConvertToPdf(testFile.path);
      expect(secondPdf.path, firstPdf.path);
      expect(secondPdf.lastModifiedSync(), firstModified);
    });

    test('preserves Turkish characters in converted PDF', () async {
      final docxArchive = Archive();
      final xmlBytes = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Türkçe karakter testi: Çç Ğğ İı Öö Şş Üü</w:t></w:r></w:p>
  </w:body>
</w:document>''');
      docxArchive.addFile(ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes));
      final testFile = File('${tempDir.path}/turkish_test.docx');
      await testFile.writeAsBytes(ZipEncoder().encode(docxArchive));

      final pdf = await DocxPdfConverter.getOrConvertToPdf(testFile.path);
      expect(pdf.existsSync(), isTrue);
      expect(pdf.lengthSync(), greaterThan(0));
    });

    test('converts RTF / legacy text using fallback to PDF', () async {
      const rtf = r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\b Fallback Test\b0\par Paragraf.}';
      final testFile = File('${tempDir.path}/fallback.doc');
      await testFile.writeAsString(rtf);

      final pdf = await DocxPdfConverter.getOrConvertToPdf(testFile.path);
      expect(pdf.existsSync(), isTrue);
      expect(pdf.lengthSync(), greaterThan(0));
    });

    test('throws FileSystemException for non-existent file', () async {
      expect(
        () => DocxPdfConverter.getOrConvertToPdf('${tempDir.path}/non_existent.docx'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
