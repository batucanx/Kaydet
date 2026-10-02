import 'package:flutter_quill/quill_delta.dart';

import '../../data/database/app_database.dart';

/// İmzayı (metin + uzak görsel URL'si) Quill Delta veya HTML formatına dönüştüren yardımcı.
abstract final class SignatureFormatter {
  /// Bir [SignatureRow]'dan Quill Delta belgesi üretir.
  static Delta toDelta(SignatureRow signature) {
    final delta = Delta();
    final body = signature.body.trim();
    final imageType = signature.imageType;
    final imageWidth = signature.imageWidth;
    final imagePosition = signature.imagePosition;

    String? imageSource;
    if (imageType == 'remote' &&
        signature.remoteImageUrl != null &&
        signature.remoteImageUrl!.trim().isNotEmpty) {
      imageSource = signature.remoteImageUrl!.trim();
    }

    final hasImage = imageSource != null && imageSource.isNotEmpty;
    final hasText = body.isNotEmpty;

    if (!hasImage && !hasText) {
      return delta;
    }

    void insertImage() {
      if (!hasImage) return;
      delta.insert(
        {'image': imageSource},
        {'width': imageWidth},
      );
      delta.insert('\n');
    }

    void insertText() {
      if (!hasText) return;
      delta.insert(body);
      delta.insert('\n');
    }

    if (hasImage && hasText) {
      if (imagePosition == 'top') {
        insertImage();
        insertText();
      } else {
        insertText();
        insertImage();
      }
    } else if (hasImage) {
      insertImage();
    } else {
      insertText();
    }

    return delta;
  }

  /// Gövde içinde bu imzanın daha önce eklenip eklenmediğini kontrol eder.
  static bool isAlreadyInserted(String bodyText, SignatureRow signature) {
    final text = signature.body.trim();
    if (text.isNotEmpty) {
      if (bodyText.contains(text)) return true;
      final jsonEscaped =
          text.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n');
      if (bodyText.contains(jsonEscaped)) return true;
    }
    final imageSource = signature.remoteImageUrl;
    if (imageSource != null &&
        imageSource.isNotEmpty &&
        bodyText.contains(imageSource)) {
      return true;
    }
    return false;
  }
}
