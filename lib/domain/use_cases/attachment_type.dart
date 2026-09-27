import 'package:path/path.dart' as p;

import 'share_attachment_policy.dart';

/// Bir ekin önizleme/ikon davranışını belirleyen kaba tür.
///
/// MIME type ile uzantı birlikte kullanılır (bkz. [AttachmentType.resolve]):
/// sunucu her zaman doğru `Content-Type` vermez, uzantı ise her zaman
/// mevcuttur. `text`, hem düz metni hem de XML/HTML/SVG/JSON gibi kaynak
/// tabanlı biçimleri kapsar — bunlar İÇERİK olarak değil, ham METİN olarak
/// gösterilir (bkz. `AttachmentPreviewScreen`): bir HTML/SVG ekini
/// `WebView`de RENDER etmek, ekin içindeki script'i çalıştırma riski taşır.
enum AttachmentKind {
  pdf,
  image,
  text,
  document,
  spreadsheet,
  presentation,
  archive,
  audio,
  video,

  /// Yürütülebilir/kurulum dosyası — önizlenemez, sadece open-with/kaydet/
  /// paylaş sunulur (bkz. `ShareAttachmentPolicy.blockedExtensions`).
  executable,
  unknown,
}

/// MIME type + dosya adından [AttachmentKind] ve görüntülenecek kısa tür
/// etiketini (`PDF`, `XML`, `DOCX`…) çıkarır.
abstract final class AttachmentType {
  static const Set<String> _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.heic',
    '.heif',
    '.bmp',
  };

  static const Set<String> _documentExtensions = {
    '.doc',
    '.docx',
    '.odt',
    '.rtf',
  };

  static const Set<String> _spreadsheetExtensions = {
    '.xls',
    '.xlsx',
    '.csv',
    '.ods',
  };

  static const Set<String> _presentationExtensions = {'.ppt', '.pptx', '.odp'};

  static const Set<String> _archiveExtensions = {
    '.zip',
    '.rar',
    '.7z',
    '.tar',
    '.gz',
    '.tgz',
  };

  static const Set<String> _audioExtensions = {
    '.mp3',
    '.wav',
    '.m4a',
    '.aac',
    '.flac',
    '.ogg',
  };

  static const Set<String> _videoExtensions = {
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.webm',
  };

  /// Kaynak/metin tabanlı biçimler — ham metin olarak gösterilir. CSV
  /// burada YOKTUR: kullanıcı için bir e-tablodur (bkz. [_spreadsheetExtensions]
  /// ve altındaki erken denetim).
  static const Set<String> _textExtensions = {
    '.txt',
    '.json',
    '.xml',
    '.html',
    '.htm',
    '.svg',
    '.css',
    '.js',
    '.ts',
    '.dart',
    '.java',
    '.py',
    '.c',
    '.cpp',
    '.h',
    '.md',
    '.yaml',
    '.yml',
    '.log',
  };

  static AttachmentKind resolve({
    required String mimeType,
    required String fileName,
  }) {
    final extension = p.extension(fileName).toLowerCase();
    if (ShareAttachmentPolicy.blockedExtensions.contains(extension)) {
      return AttachmentKind.executable;
    }

    // E-posta sunucuları Content-Type parametrelerini (ör. `; name=...`)
    // ekleyebilir. Kararı parametresiz MIME türü üzerinden ver; özellikle
    // uzantısı olmayan Office eklerinin yine de önizlemeye ulaşması gerekir.
    final mime = mimeType.toLowerCase().split(';').first.trim();
    // CSV bazı sunucularda `text/csv` gelir ama kullanıcı için bir e-tablodur;
    // uzantı burada MIME'dan önce sorulur.
    if (extension == '.csv') return AttachmentKind.spreadsheet;
    if (_textExtensions.contains(extension)) return AttachmentKind.text;
    if (_imageExtensions.contains(extension)) return AttachmentKind.image;
    if (_documentExtensions.contains(extension)) return AttachmentKind.document;
    if (_spreadsheetExtensions.contains(extension)) {
      return AttachmentKind.spreadsheet;
    }
    if (_presentationExtensions.contains(extension)) {
      return AttachmentKind.presentation;
    }
    if (_archiveExtensions.contains(extension)) return AttachmentKind.archive;
    if (_audioExtensions.contains(extension)) return AttachmentKind.audio;
    if (_videoExtensions.contains(extension)) return AttachmentKind.video;

    // Uzantı tanınmadıysa MIME type'a başvurulur (ör. sunucudan uzantısız,
    // ama doğru `Content-Type` ile gelen bir ek).
    if (mime == 'application/pdf') return AttachmentKind.pdf;
    if (mime == 'application/msword' ||
        mime == 'application/rtf' ||
        mime == 'text/rtf' ||
        mime ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
        mime ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.template' ||
        mime == 'application/vnd.oasis.opendocument.text') {
      return AttachmentKind.document;
    }
    if (mime == 'application/vnd.ms-excel' ||
        mime ==
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
        mime ==
            'application/vnd.openxmlformats-officedocument.spreadsheetml.template' ||
        mime == 'application/vnd.oasis.opendocument.spreadsheet') {
      return AttachmentKind.spreadsheet;
    }
    if (mime == 'application/vnd.ms-powerpoint' ||
        mime ==
            'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
        mime == 'application/vnd.oasis.opendocument.presentation') {
      return AttachmentKind.presentation;
    }
    if (mime.startsWith('image/')) return AttachmentKind.image;
    if (mime.startsWith('audio/')) return AttachmentKind.audio;
    if (mime.startsWith('video/')) return AttachmentKind.video;
    if (mime.startsWith('text/')) return AttachmentKind.text;
    if (mime == 'application/zip' ||
        mime == 'application/x-7z-compressed' ||
        mime == 'application/x-rar-compressed' ||
        mime == 'application/x-tar' ||
        mime == 'application/gzip') {
      return AttachmentKind.archive;
    }

    if (extension == '.pdf') return AttachmentKind.pdf;
    return AttachmentKind.unknown;
  }

  /// Kart/önizlemede gösterilen kısa tür etiketi: `PDF`, `XML`, `DOCX`…
  /// Uzantısız dosyada `DOSYA`.
  static String label(String fileName) {
    final extension = p.extension(fileName);
    if (extension.isEmpty) return 'DOSYA';
    return extension.substring(1).toUpperCase();
  }
}
