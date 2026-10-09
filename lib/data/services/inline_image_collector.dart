import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/use_cases/cid_resolver.dart';

/// İletinin gömülü (Content-ID'li) görsel parçalarını toplar ve HTML
/// gövdesindeki `cid:` başvurularını bunlarla çözer (bkz. [CidResolver]).
abstract final class InlineImageCollector {
  /// [html] içindeki `cid:` başvurularını [message]in görsel parçalarıyla
  /// değiştirir. Hiç `cid:` yoksa parçalara dokunulmaz (bayt çözülmez).
  /// Bozuk bir parça yalnızca kendi görselini kaybettirir; gövdeyi bozmaz.
  static String resolve(em.MimeMessage message, String html) {
    if (!RegExp('cid:', caseSensitive: false).hasMatch(html)) return html;
    final parts = <String, ({String mimeType, Uint8List bytes})>{};
    var total = 0;

    void visit(em.MimePart part) {
      final children = part.parts;
      if (children != null && children.isNotEmpty) {
        children.forEach(visit);
        return;
      }
      try {
        final rawId = part.getHeaderValue('content-id');
        if (rawId == null) return;
        final mime = part.mediaType.text.toLowerCase();
        if (!mime.startsWith('image/')) return;
        final id = CidResolver.normalizeId(rawId);
        if (id.isEmpty || parts.containsKey(id)) return;
        final bytes = part.decodeContentBinary();
        if (bytes == null || bytes.isEmpty) return;
        if (bytes.length > CidResolver.maxImageBytes ||
            total + bytes.length > CidResolver.maxTotalBytes) {
          return;
        }
        total += bytes.length;
        parts[id] = (mimeType: mime, bytes: bytes);
      } on Object {
        // Çözülemeyen parça: yalnızca o görsel kırık kalır.
      }
    }

    visit(message);
    return CidResolver.resolve(html, parts);
  }
}
