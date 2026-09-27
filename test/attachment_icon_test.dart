import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/attachment_type.dart';
import 'package:kaydet/ui/core/widgets/attachment_icon.dart';

void main() {
  group('Attachment asset files on disk', () {
    test('all mapped icon files exist in assets/icons/', () {
      final requiredFiles = [
        'assets/icons/pdf.png',
        'assets/icons/png.png',
        'assets/icons/jpg.png',
        'assets/icons/doc.png',
        'assets/icons/sheet.png',
      ];

      for (final relPath in requiredFiles) {
        final file = File(relPath);
        expect(
          file.existsSync(),
          isTrue,
          reason: '$relPath should exist on disk',
        );
        expect(
          file.lengthSync(),
          greaterThan(0),
          reason: '$relPath should not be empty',
        );
      }
    });
  });

  group('attachmentAssetPath mapping', () {
    test('resolves by file extension', () {
      // PNG
      expect(
        attachmentAssetPath(fileName: 'screenshot.png'),
        'assets/icons/png.png',
      );
      expect(
        attachmentAssetPath(fileName: 'IMAGE.PNG'),
        'assets/icons/png.png',
      );

      // JPG / JPEG
      expect(
        attachmentAssetPath(fileName: 'photo.jpg'),
        'assets/icons/jpg.png',
      );
      expect(
        attachmentAssetPath(fileName: 'picture.jpeg'),
        'assets/icons/jpg.png',
      );
      expect(
        attachmentAssetPath(fileName: 'BANNER.JPG'),
        'assets/icons/jpg.png',
      );

      // PDF
      expect(
        attachmentAssetPath(fileName: 'report.pdf'),
        'assets/icons/pdf.png',
      );
      expect(
        attachmentAssetPath(fileName: 'DOCUMENT.PDF'),
        'assets/icons/pdf.png',
      );

      // Word / Documents
      expect(
        attachmentAssetPath(fileName: 'letter.doc'),
        'assets/icons/doc.png',
      );
      expect(
        attachmentAssetPath(fileName: 'contract.docx'),
        'assets/icons/doc.png',
      );
      expect(
        attachmentAssetPath(fileName: 'notes.odt'),
        'assets/icons/doc.png',
      );

      // Spreadsheets / Sheets
      expect(
        attachmentAssetPath(fileName: 'budget.xls'),
        'assets/icons/sheet.png',
      );
      expect(
        attachmentAssetPath(fileName: 'data.xlsx'),
        'assets/icons/sheet.png',
      );
      expect(
        attachmentAssetPath(fileName: 'table.csv'),
        'assets/icons/sheet.png',
      );
      expect(
        attachmentAssetPath(fileName: 'export.ods'),
        'assets/icons/sheet.png',
      );
    });

    test('resolves by MIME type when fileName is missing or extension unknown', () {
      expect(
        attachmentAssetPath(mimeType: 'image/png'),
        'assets/icons/png.png',
      );
      expect(
        attachmentAssetPath(mimeType: 'image/jpeg'),
        'assets/icons/jpg.png',
      );
      expect(
        attachmentAssetPath(mimeType: 'application/pdf'),
        'assets/icons/pdf.png',
      );
      expect(
        attachmentAssetPath(
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        'assets/icons/doc.png',
      );
      expect(
        attachmentAssetPath(
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        'assets/icons/sheet.png',
      );
      expect(
        attachmentAssetPath(mimeType: 'text/csv'),
        'assets/icons/sheet.png',
      );
    });

    test('resolves by AttachmentKind fallback', () {
      expect(
        attachmentAssetPath(kind: AttachmentKind.pdf),
        'assets/icons/pdf.png',
      );
      expect(
        attachmentAssetPath(kind: AttachmentKind.document),
        'assets/icons/doc.png',
      );
      expect(
        attachmentAssetPath(kind: AttachmentKind.spreadsheet),
        'assets/icons/sheet.png',
      );
    });

    test('returns null for formats without dedicated png icon', () {
      expect(attachmentAssetPath(fileName: 'song.mp3'), isNull);
      expect(attachmentAssetPath(fileName: 'movie.mp4'), isNull);
      expect(attachmentAssetPath(fileName: 'archive.zip'), isNull);
      expect(attachmentAssetPath(fileName: 'code.dart'), isNull);
    });
  });

  group('AttachmentType MIME classification', () {
    test('routes extensionless Office attachments to their in-app preview', () {
      expect(
        AttachmentType.resolve(
          fileName: 'dosya',
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document; name=dosya',
        ),
        AttachmentKind.document,
      );
      expect(
        AttachmentType.resolve(
          fileName: 'ek',
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        AttachmentKind.spreadsheet,
      );
    });
  });

  group('AttachmentTypeIcon widget', () {
    testWidgets('renders Image for supported custom formats', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AttachmentTypeIcon(fileName: 'photo.png', size: 24),
          ),
        ),
      );

      final imageFinder = find.byType(Image);
      expect(imageFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imageFinder);
      expect(
        (imageWidget.image as AssetImage).assetName,
        'assets/icons/png.png',
      );
      expect(imageWidget.width, 24);
      expect(imageWidget.height, 24);
    });

    testWidgets('renders fallback Icon for unsupported formats', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AttachmentTypeIcon(fileName: 'music.mp3', size: 24),
          ),
        ),
      );

      final iconFinder = find.byType(Icon);
      expect(iconFinder, findsOneWidget);
    });
  });
}
