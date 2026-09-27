# DOCX Image Preview Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the DOCX preview to render embedded images (drawing/pict elements) inline with text, matching the original document appearance as shown in the reference images.

**Architecture:** The current DocxParser extracts text from `drawing` and `pict` elements but discards the actual image data. We need to: (1) Parse image relationships from `word/_rels/document.xml.rels`, (2) Extract image files from the ZIP archive (typically under `word/media/`), (3) Associate images with their anchor positions in paragraphs, (4) Render images inline using Flutter's `Image.memory` widget within the preview.

**Tech Stack:** Flutter, `archive` package (already used), `xml` package (already used), standard Flutter widgets.

**Spec:** User reference images show the original DOCX has images embedded in paragraphs that should render inline in the preview.

## Global Constraints

- Maintain existing parser API (`DocxParser.parseBytes` / `parseFile` returning `DocxDocument`)
- No breaking changes to `DocxPreviewWidget` or `DocxBlock` hierarchy
- Images must be loaded from the same ZIP archive (no network fetches)
- Handle both `w:drawing` (modern) and `w:pict` (legacy) image formats
- Support inline images (anchor type `inline`) and floating images (basic support)
- Memory-efficient: decode images on-demand, not all at parse time
- Maintain aspect ratio, constrain max width to page width

---

## File Structure Changes

### New Files
- `lib/ui/features/attachment_preview/docx_image_resolver.dart` - Handles image extraction and mapping from docx ZIP
- `lib/ui/features/attachment_preview/docx_inline_image.dart` - Widget for rendering inline images

### Modified Files
- `lib/ui/features/attachment_preview/docx_viewer.dart` - Main parser and preview widget updates
- `test/docx_and_spreadsheet_preview_test.dart` - Add tests for image parsing

---

## Task Breakdown

### Task 1: Create DocxImageResolver - Extract and Map Images from ZIP

**Files:**
- Create: `lib/ui/features/attachment_preview/docx_image_resolver.dart`

**Interfaces:**
- Produces: `DocxImageResolver` class with method `resolveImages(Archive archive) -> DocxImageMap`
- `DocxImageMap` contains: `Map<String, Uint8List> imagesByRelId` (rId -> image bytes), `Map<String, String> relIdToMediaPath` (rId -> media path)

```dart
// Step 1: Write failing test
test('DocxImageResolver extracts images from document.xml.rels and media folder', () {
  final archive = _createTestArchiveWithImage();
  final resolver = DocxImageResolver();
  final map = resolver.resolve(archive);
  
  expect(map.imagesByRelId, isNotEmpty);
  expect(map.imagesByRelId.keys.first, startsWith('rId'));
  expect(map.imagesByRelId.values.first.length, greaterThan(100));
});
```

```dart
// Step 2: Run test - expect FAIL (class doesn't exist)

// Step 3: Minimal implementation
class DocxImageResolver {
  DocxImageMap resolve(Archive archive) {
    // 1. Read word/_rels/document.xml.rels
    // 2. Parse Relationship elements: Id (rId), Target (media/image1.png), Type
    // 3. For each image relationship, read bytes from archive (word/media/...)
    // 4. Return map
  }
}

class DocxImageMap {
  final Map<String, Uint8List> imagesByRelId;
  final Map<String, String> relIdToMediaPath;
  const DocxImageMap({required this.imagesByRelId, required this.relIdToMediaPath});
}
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 2: Update DocxParser to Parse Image Anchors and Associate with Runs

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (parser section)

**Interfaces:**
- Consumes: `DocxImageMap` from Task 1
- Produces: Updated `DocxRun` model with optional `inlineImages` field, updated `_parseParagraph` to collect image anchors

```dart
// Step 1: Write failing test
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

```dart
// Step 2: Run test - expect FAIL

// Step 3: Implementation - Update DocxRun model and parser
class DocxRun {
  // ... existing fields ...
  final List<DocxInlineImage> inlineImages;
  const DocxRun({..., this.inlineImages = const []});
}

class DocxInlineImage {
  final String relId;
  final double? widthEmu;
  final double? heightEmu;
  final String? altText;
  const DocxInlineImage({required this.relId, this.widthEmu, this.heightEmu, this.altText});
}

// In _parseRun: when encountering 'drawing' or 'pict', extract:
// - wp:inline/wp:extent @cx, @cy (size in EMU)
// - a:blip r:embed (the rId)
// - docPr @descr (alt text)
// Store as DocxInlineImage in the run
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 3: Create DocxInlineImageWidget for Rendering Images Inline

**Files:**
- Create: `lib/ui/features/attachment_preview/docx_inline_image.dart`

**Interfaces:**
- Consumes: `DocxInlineImage` (relId), `DocxImageMap` (for bytes), maxWidth constraint
- Produces: `DocxInlineImageWidget` - StatelessWidget that renders image inline with text

```dart
// Step 1: Write failing test
testWidgets('DocxInlineImageWidget renders image with correct aspect ratio', (tester) async {
  final imageBytes = _createTestPngBytes(200, 100);
  final imageMap = DocxImageMap(
    imagesByRelId: {'rId1': imageBytes},
    relIdToMediaPath: {'rId1': 'word/media/image1.png'},
  );
  
  await tester.pumpWidget(MaterialApp(
    home: DocxInlineImageWidget(
      image: DocxInlineImage(relId: 'rId1', widthEmu: 1800000, heightEmu: 900000),
      imageMap: imageMap,
      maxWidth: 400,
    ),
  ));
  
  expect(find.byType(Image), findsOneWidget);
  // Verify aspect ratio preserved
});
```

```dart
// Step 2: Run test - expect FAIL

// Step 3: Implementation
class DocxInlineImageWidget extends StatelessWidget {
  final DocxInlineImage image;
  final DocxImageMap imageMap;
  final double maxWidth;
  
  const DocxInlineImageWidget({
    required this.image,
    required this.imageMap,
    required this.maxWidth,
  });
  
  @override
  Widget build(BuildContext context) {
    final bytes = imageMap.imagesByRelId[image.relId];
    if (bytes == null) return SizedBox.shrink();
    
    // Calculate display size from EMU (1 inch = 914400 EMU)
    // Constrain to maxWidth, maintain aspect ratio
    // Use Image.memory with fit: BoxFit.contain
  }
}
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 4: Update DocxPreviewWidget to Pass ImageMap and Render Inline Images

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (preview widget section)

**Interfaces:**
- Consumes: `DocxImageMap` from parser, `DocxInlineImageWidget` from Task 3
- Produces: Updated preview that shows images inline within paragraphs

```dart
// Step 1: Write failing test
testWidgets('DocxPreviewWidget renders inline images in paragraph', (tester) async {
  final archive = _createTestDocxWithInlineImage();
  final file = await _writeTempFile(archive);
  
  await tester.pumpWidget(MaterialApp(home: DocxPreviewWidget(path: file.path, attachment: _dummyAttachment())));
  await tester.pump();
  
  expect(find.byType(DocxInlineImageWidget), findsOneWidget);
});
```

```dart
// Step 2: Run test - expect FAIL

// Step 3: Implementation
// In _DocxPreviewWidgetState:
// 1. Parse archive once in initState, extract DocxImageMap
// 2. Pass DocxImageMap to _buildParagraph/_buildBlock
// 4. In _buildParagraph: after building TextSpan for a run, if run.inlineImages not empty,
//    wrap in Row/Column with image widgets interleaved
// 5. Handle multiple images per run, images between text runs

// In _buildParagraph:
// - Build a list of widgets: TextSpan chunks + DocxInlineImageWidget
// - Use RichText with WidgetSpan for images, TextSpan for text
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 5: Handle Floating/Anchored Images (wp:anchor) - Basic Support

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (parser)

**Interfaces:**
- Consumes: Same as Task 2
- Produces: Parsed `DocxFloatingImage` blocks that can be rendered as separate block-level widgets

```dart
// Step 1: Write failing test
test('DocxParser extracts floating images from anchor elements', () {
  final xml = _createDocxXmlWithFloatingImage();
  final doc = DocxParser.parseBytes(_createArchiveWithImageAndRels(xml));
  
  expect(doc.blocks.any((b) => b is DocxFloatingImageBlock), isTrue);
});
```

```dart
// Step 2: Run test - expect FAIL

// Step 3: Implementation
// Add DocxFloatingImageBlock to DocxBlock hierarchy
// In extractBlocks: detect wp:anchor (not wp:inline) -> create DocxFloatingImageBlock
// Store: relId, positionH, positionV, extent, wrapType, behindDoc

// In preview: render floating images as centered block with max width constraint
// For now: treat as block-level centered image (simpler than true text wrapping)
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 6: Handle Legacy w:pict Format (Word 97-2003 Compatibility)

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_viewer.dart` (parser `_parseRun`)

**Interfaces:**
- Consumes: Same image resolver
- Produces: Images from `v:shape`/`v:imagedata` with `r:id` attribute

```dart
// Step 1: Write failing test
test('DocxParser extracts images from legacy pict/v:shape elements', () {
  final xml = _createDocxXmlWithLegacyPict();
  final doc = DocxParser.parseBytes(_createArchiveWithImageAndRels(xml));
  
  final run = (doc.blocks.first as DocxParagraphBlock).paragraph.runs.first;
  expect(run.inlineImages, isNotEmpty);
});
```

```dart
// Step 2: Run test - expect FAIL

// Step 3: Implementation
// In _parseRun, when name == 'pict':
// - Find v:shape -> v:imagedata @r:id (or o:relid)
// - Extract size from v:shape @style (width:xxx;height:yyy)
// - Create DocxInlineImage with relId
```

```dart
// Step 4: Run test - expect PASS

// Step 5: Commit
```

---

### Task 7: Integration Test with Real DOCX File

**Files:**
- Modify: `test/docx_and_spreadsheet_preview_test.dart`

**Interfaces:**
- Consumes: All previous tasks
- Produces: End-to-end test verifying images render

```dart
// Step 1: Write failing test
testWidgets('DocxPreviewWidget renders complete document with images matching reference', (tester) async {
  // Use a real test .docx file with known structure
  final file = File('test/fixtures/sample_with_images.docx');
  if (!await file.exists()) return; // Skip if fixture missing
  
  await tester.pumpWidget(MaterialApp(home: DocxPreviewWidget(...)));
  await tester.pumpAndSettle();
  
  // Verify images present
  expect(find.byType(Image), findsWidgets);
  // Verify no errors
  expect(find.text('Belge önizlemesi yüklenemedi'), findsNothing);
});
```

```dart
// Step 2: Run test - expect FAIL (until all tasks done)

// Step 3: After all tasks complete, run - expect PASS

// Step 4: Commit
```

---

### Task 8: Performance Optimization - Lazy Image Loading

**Files:**
- Modify: `lib/ui/features/attachment_preview/docx_inline_image.dart`

**Interfaces:**
- Consumes: `DocxImageMap` with bytes
- Produces: Widget that loads image only when visible (using `Image.memory` with `gaplessPlayback` or `ResizeImage`)

```dart
// Step 1: Write test for memory behavior (optional, visual verification)

// Step 2: Implementation
// - Use ResizeImage to decode at display size, not full resolution
// - Add cacheWidth/cacheHeight based on calculated display size
// - Consider using Image.memory with Uint8List (already in memory from ZIP)
// - For very large documents, consider lazy loading (only decode when scrolled into view)
```

```dart
// Step 3: Manual verification with large image DOCX

// Step 4: Commit
```

---

## Execution Order

1. **Task 1** (Image Resolver) → Foundation for all image handling
2. **Task 2** (Parser Updates) → Associate images with runs
3. **Task 3** (Inline Image Widget) → Rendering primitive
4. **Task 4** (Preview Integration) → Wire it all together
5. **Task 5** (Floating Images) → Enhanced support
6. **Task 6** (Legacy Pict) → Backward compatibility
7. **Task 7** (Integration Test) → Verify end-to-end
8. **Task 8** (Optimization) → Polish

---

## Acceptance Criteria

- [ ] DOCX with inline images renders images at correct positions in paragraphs
- [ ] Image aspect ratio preserved, constrained to page width
- [ ] Both modern (`w:drawing` with `wp:inline`) and legacy (`w:pict` with `v:shape`) formats work
- [ ] Floating images (`wp:anchor`) render as block-level centered images
- [ ] No regression in text, table, list rendering
- [ ] Memory usage reasonable for documents with many images
- [ ] All existing tests pass
- [ ] New tests cover image parsing and rendering

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-27-docx-image-preview-fix.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**