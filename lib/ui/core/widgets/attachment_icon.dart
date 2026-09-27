import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../../domain/use_cases/attachment_type.dart';
import '../theme/tokens.dart';

/// [kind]'a göre dosya ikonu.
IconData attachmentIconData(AttachmentKind kind) => switch (kind) {
  AttachmentKind.pdf => LucideIcons.fileText,
  AttachmentKind.image => LucideIcons.fileImage,
  AttachmentKind.text => LucideIcons.fileCode,
  AttachmentKind.document => LucideIcons.fileText,
  AttachmentKind.spreadsheet => LucideIcons.fileSpreadsheet,
  AttachmentKind.presentation => LucideIcons.presentation,
  AttachmentKind.archive => LucideIcons.fileArchive,
  AttachmentKind.audio => LucideIcons.fileAudio,
  AttachmentKind.video => LucideIcons.fileVideo,
  AttachmentKind.executable => LucideIcons.shieldAlert,
  AttachmentKind.unknown => LucideIcons.file,
};

/// Dosya uzantısı, MIME türü veya tür grubuna göre özel görsel ikon dosya yolu.
///
/// Özel ikon tanımlı değilse `null` döner; bu durumda [AttachmentTypeIcon]
/// vektörel [attachmentIconData] ikonuna geri düşer.
String? attachmentAssetPath({
  String? fileName,
  String? mimeType,
  AttachmentKind? kind,
}) {
  final ext = fileName != null && fileName.contains('.')
      ? p.extension(fileName).toLowerCase().trim()
      : '';

  // 1. Dosya uzantısına göre birebir eşleştirme
  if (ext == '.png') return 'assets/icons/png.png';
  if (ext == '.jpg' || ext == '.jpeg' || ext == '.jpe') {
    return 'assets/icons/jpg.png';
  }
  if (ext == '.pdf') return 'assets/icons/pdf.png';
  if (const {'.doc', '.docx', '.odt', '.rtf', '.dot', '.dotx'}.contains(ext)) {
    return 'assets/icons/doc.png';
  }
  if (const {'.xls', '.xlsx', '.csv', '.ods', '.xlsm', '.tsv'}.contains(ext)) {
    return 'assets/icons/sheet.png';
  }

  // 2. MIME türüne göre eşleştirme (uzantısız veya sunucu yanıtı durumunda)
  final mime = mimeType?.toLowerCase().split(';').first.trim() ?? '';
  if (mime == 'image/png') return 'assets/icons/png.png';
  if (mime == 'image/jpeg' || mime == 'image/jpg') {
    return 'assets/icons/jpg.png';
  }
  if (mime == 'application/pdf') return 'assets/icons/pdf.png';
  if (mime == 'application/msword' ||
      mime == 'application/rtf' ||
      mime == 'text/rtf' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.template' ||
      mime == 'application/vnd.oasis.opendocument.text') {
    return 'assets/icons/doc.png';
  }
  if (mime == 'application/vnd.ms-excel' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.template' ||
      mime == 'application/vnd.oasis.opendocument.spreadsheet' ||
      mime == 'text/csv') {
    return 'assets/icons/sheet.png';
  }

  // 3. AttachmentKind genel türüne göre eşleştirme
  return switch (kind) {
    AttachmentKind.pdf => 'assets/icons/pdf.png',
    AttachmentKind.document => 'assets/icons/doc.png',
    AttachmentKind.spreadsheet => 'assets/icons/sheet.png',
    _ => null,
  };
}

/// Ek türüne göre renklendirilmiş veya özel format görseli içeren dosya ikonu.
///
/// PDF, PNG, JPG, DOC ve E-Tablo gibi formatlar için `assets/icons/` altındaki
/// özel format ikonları kullanılır. Diğer türler veya görsel yüklenememesi
/// durumunda tasarım sisteminin [KaydetTokens.avatarTones] rampasına göre
/// renklendirilmiş vektörel Lucide ikonuna geri düşülür.
class AttachmentTypeIcon extends StatelessWidget {
  const AttachmentTypeIcon({
    super.key,
    this.kind,
    this.fileName,
    this.mimeType,
    this.size = IconSize.lg,
  });

  final AttachmentKind? kind;
  final String? fileName;
  final String? mimeType;
  final double size;

  static const Map<AttachmentKind, int> _toneIndex = {
    AttachmentKind.pdf: 0,
    AttachmentKind.image: 6,
    AttachmentKind.document: 9,
    AttachmentKind.spreadsheet: 5,
    AttachmentKind.presentation: 3,
    AttachmentKind.archive: 10,
    AttachmentKind.audio: 12,
    AttachmentKind.video: 1,
    AttachmentKind.text: 8,
  };

  Color _iconColor(KaydetTokens t, AttachmentKind k) => switch (k) {
    AttachmentKind.executable => t.danger,
    AttachmentKind.unknown => t.textTertiary,
    _ => t.toneAt(_toneIndex[k] ?? 0).foreground,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final resolvedKind =
        kind ??
        AttachmentType.resolve(
          mimeType: mimeType ?? '',
          fileName: fileName ?? '',
        );

    final asset = attachmentAssetPath(
      fileName: fileName,
      mimeType: mimeType,
      kind: resolvedKind,
    );

    if (asset != null) {
      return Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Icon(
          attachmentIconData(resolvedKind),
          size: size,
          color: _iconColor(t, resolvedKind),
        ),
      );
    }

    return Icon(
      attachmentIconData(resolvedKind),
      size: size,
      color: _iconColor(t, resolvedKind),
    );
  }
}
