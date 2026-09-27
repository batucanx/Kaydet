import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Resolves image relationships from a DOCX archive.
///
/// Reads `word/_rels/document.xml.rels` to map relationship IDs (rId) to
/// media paths, then extracts the image bytes from the archive.
class DocxImageResolver {
  const DocxImageResolver();

  /// Extracts all images from a DOCX archive.
  ///
  /// Returns a [DocxImageMap] containing:
  /// - `imagesByRelId`: Maps relationship IDs (e.g., 'rId4') to image bytes
  /// - `relIdToMediaPath`: Maps relationship IDs to their media paths in the archive
  DocxImageMap resolve(Archive archive) {
    final filesMap = <String, ArchiveFile>{};
    for (final file in archive.files) {
      filesMap[file.name.replaceAll('\\', '/')] = file;
    }

    // Find the document relationships file
    ArchiveFile? relsFile = filesMap['word/_rels/document.xml.rels'];
    if (relsFile == null) {
      // Try case-insensitive search
      for (final entry in filesMap.entries) {
        if (entry.key.toLowerCase() == 'word/_rels/document.xml.rels') {
          relsFile = entry.value;
          break;
        }
      }
    }

    if (relsFile == null) {
      return const DocxImageMap(
        imagesByRelId: {},
        relIdToMediaPath: {},
      );
    }

    final relsXml = utf8.decode(
      relsFile.content as List<int>,
      allowMalformed: true,
    );
    final relsDoc = XmlDocument.parse(relsXml);

    // Parse relationships: rId -> Target (media path)
    final relIdToMediaPath = <String, String>{};
    const imageRelType = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';

    for (final rel in relsDoc.findAllElements('Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      final type = rel.getAttribute('Type');

      if (id != null && target != null && type == imageRelType) {
        // Normalize target path: 'media/image1.png' -> 'word/media/image1.png'
        String mediaPath = target;
        if (!mediaPath.startsWith('word/') && !mediaPath.startsWith('/')) {
          mediaPath = 'word/$mediaPath';
        } else if (mediaPath.startsWith('/')) {
          mediaPath = mediaPath.substring(1);
        }
        relIdToMediaPath[id] = mediaPath.replaceAll('\\', '/');
      }
    }

    // Extract image bytes for each relationship
    final imagesByRelId = <String, Uint8List>{};
    for (final entry in relIdToMediaPath.entries) {
      final relId = entry.key;
      final mediaPath = entry.value;

      final imageFile = filesMap[mediaPath];
      if (imageFile != null) {
        final content = imageFile.content as List<int>;
        imagesByRelId[relId] = Uint8List.fromList(content);
      }
    }

    return DocxImageMap(
      imagesByRelId: imagesByRelId,
      relIdToMediaPath: relIdToMediaPath,
    );
  }
}

/// Container for resolved DOCX image data.
class DocxImageMap {
  const DocxImageMap({
    required this.imagesByRelId,
    required this.relIdToMediaPath,
  });

  /// Maps relationship IDs (e.g., 'rId4') to image bytes.
  final Map<String, Uint8List> imagesByRelId;

  /// Maps relationship IDs to their media paths in the archive.
  final Map<String, String> relIdToMediaPath;

  /// Returns true if no images were found.
  bool get isEmpty => imagesByRelId.isEmpty;

  /// Returns the number of resolved images.
  int get length => imagesByRelId.length;
}