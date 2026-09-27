# Docx Inline Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `DocxParser` in `lib/ui/features/attachment_preview/docx_viewer.dart` to parse image anchors and associate them with runs using `DocxImageResolver` from Task 1.

**Architecture:** 
- Create `DocxInlineImage` model class to hold inline image metadata (relId, width/height in EMU, altText)
- Update `DocxRun` to include a list of `DocxInlineImage`
- Modify `_parseRun` to extract inline images from `w:drawing` and `w:pict` elements
- Modify `_parseDocxZip` to resolve images once via `DocxImageResolver` and pass the image map through parsing
- Store `DocxImageMap` in `DocxDocument` for later use by preview widget

**Tech Stack:** Dart, Flutter, package:xml, package:archive

**Spec:** Based on requirements in the task description

## Global Constraints

- Follow existing patterns in `docx_viewer.dart`
- Use the `archive` and `xml` packages already imported
- Maintain backward compatibility - runs without images should work as before
- Test file: `test/docx_and_spreadsheet_preview_test.dart`

---

### Task 1: Create DocxInlineImage model class

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (around line 703, after DocxRun)

**Interfaces:**
- Produces: `DocxInlineImage` class with properties: `relId` (String), `widthEmu` (int), `heightEmu` (int), `altText` (String?)

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: FAIL with "DocxInlineImage not defined"

- [ ] **Step 3: Write minimal implementation**

Add `DocxInlineImage` class after `DocxRun` class (around line 721).

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart::DocxInlineImage -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/features/attachment_preview/docx_viewer.dart test/docx_and_spreadsheet_preview_test.dart
git commit -m "feat: add DocxInlineImage model class"
```

---

### Task 2: Update DocxRun to include inlineImages list

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (DocxRun class around line 703-721)

**Interfaces:**
- Consumes: `DocxInlineImage` from Task 1
- Produces: Updated `DocxRun` with `inlineImages: List<DocxInlineImage>` parameter

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: FAIL with "inlineImages parameter not found"

- [ ] **Step 3: Write minimal implementation**

Update `DocxRun` class to add `inlineImages` field and parameter.

```dart
class DocxRun {
  const DocxRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.fontSize,
    this.inlineImages = const [],
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final Color? color;
  final double? fontSize;
  final List<DocxInlineImage> inlineImages;  // NEW
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart::DocxRun -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/features/attachment_preview/docx_viewer.dart test/docx_and_spreadsheet_preview_test.dart
git commit -m "feat: add inlineImages to DocxRun"
```

---

### Task 3: Implement _parseInlineImages helper and update _parseRun

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (_parseRun method around line 276-350)

**Interfaces:**
- Consumes: `DocxInlineImage`, `DocxImageMap` (for validation)
- Produces: Updated `_parseRun` that extracts inline images from `drawing` and `pict` elements

- [ ] **Step 1: Write the failing test**

```dart
test('DocxParser extracts inline images from drawing elements with correct rId', () {
  final xml = _createDocxXmlWithInlineImage();
  final archive = _createArchiveWithImageAndRels(xml);
  final doc = DocxParser.parseBytes(archiveBytes);
  
  final para = doc.blocks.first as DocxParagraphBlock;
  final run = para.paragraph.runs.first;
  expect(run.inlineImages, isNotEmpty);
  expect(run.inlineImages.first.relId, 'rId4');
});
```

Helper functions needed:
- `_createDocxXmlWithInlineImage()` - Returns XML string with w:drawing containing wp:inline, wp:extent, a:blip
- `_createArchiveWithImageAndRels(xml)` - Creates Archive with document.xml, document.xml.rels, and a dummy image in word/media/

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: FAIL - inlineImages not extracted

- [ ] **Step 3: Write minimal implementation**

1. Add `_parseInlineImages` helper method that takes `XmlElement runElement` and `DocxImageMap imageMap`
2. In `_parseRun`, after collecting text, call `_parseInlineImages` and add results to run
3. Handle both `w:drawing` (with `wp:inline`, `wp:extent`, `a:blip`) and `w:pict` (with `v:shape`, `v:imagedata`)

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart::DocxParser -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/features/attachment_preview/docx_viewer.dart test/docx_and_spreadsheet_preview_test.dart
git commit -m "feat: parse inline images from drawing and pict elements"
```

---

### Task 4: Update _parseDocxZip to resolve images and pass to parsing

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (_parseDocxZip method around line 78-144)

**Interfaces:**
- Consumes: `DocxImageResolver.resolve()` returning `DocxImageMap`
- Produces: Updated `_parseDocxZip` that resolves images once and stores in `DocxDocument`

- [ ] **Step 1: Write the failing test**

```dart
test('DocxDocument stores DocxImageMap from archive', () {
  final archive = _createArchiveWithImageAndRels(_createDocxXmlWithInlineImage());
  final doc = DocxParser.parseBytes(ZipEncoder().encode(archive)!);
  
  expect(doc.imageMap, isNotNull);
  expect(doc.imageMap!.imagesByRelId.containsKey('rId4'), isTrue);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: FAIL - DocxDocument doesn't have imageMap field

- [ ] **Step 3: Write minimal implementation**

1. Update `DocxDocument` to include optional `DocxImageMap? imageMap` field
2. In `_parseDocxZip`, after decoding archive:
   - Call `DocxImageResolver().resolve(archive)` to get `DocxImageMap`
   - Pass the image map to `_parseParagraph` -> `_parseRun`
   - Store the image map in `DocxDocument`

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart::DocxParser -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/features/attachment_preview/docx_viewer.dart test/docx_and_spreadsheet_preview_test.dart
git commit -m "feat: resolve images in _parseDocxZip and store in DocxDocument"
```

---

### Task 5: Update _parseParagraph and _parseRun signatures to accept imageMap

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (_parseParagraph around line 186, _parseRun around line 276)

**Interfaces:**
- Consumes: `DocxImageMap` from Task 4
- Produces: Updated method signatures that pass imageMap through

- [ ] **Step 1: Write the failing test**

Already covered by Task 4 test.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: FAIL - signature mismatch

- [ ] **Step 3: Write minimal implementation**

1. Update `_parseParagraph(XmlElement pElem, DocxImageMap imageMap)` 
2. Update `_parseRun(XmlElement rElem, {bool isLink = false, required DocxImageMap imageMap})`
3. Pass imageMap through all calls in the chain

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/features/attachment_preview/docx_viewer.dart test/docx_and_spreadsheet_preview_test.dart
git commit -m "feat: pass imageMap through paragraph and run parsing"
```

---

### Task 6: Run all tests and verify

**Files:**
- Test: `test/docx_and_spreadsheet_preview_test.dart`

**Interfaces:**
- All previous tasks

- [ ] **Step 1: Run full test suite**

Run: `flutter test test/docx_and_spreadsheet_preview_test.dart -v`
Expected: All tests PASS

- [ ] **Step 2: Run any existing tests to ensure no regression**

Run: `flutter test -v`
Expected: All tests PASS

- [ ] **Step 3: Commit final changes**

```bash
git add .
git commit -m "feat: complete Docx inline image parsing implementation"
```

---