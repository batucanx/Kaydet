import 'dart:convert';
import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../app/navigation.dart';
import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../features/compose/compose_launcher.dart';
import '../theme/tokens.dart';
import '../widgets/kaydet_notice.dart';

/// İndirilmiş/önbellekteki bir ek üzerindeki eylemler.
///
/// [message_actions.dart] ile aynı biçimde: eylemler doğrudan fonksiyon,
/// menü ise çağıranın kendi `MenuAnchor`ına ekleyeceği bir `Widget` listesi
/// (bkz. [attachmentMenuItems]) — hem `_AttachmentChip`in kendi "⋮" menüsü
/// hem de `AttachmentPreviewScreen`'in üst çubuğundaki menü AYNI listeyi
/// kullanır, iki kopya menü kodu oluşmaz.

/// Dosyayı işletim sisteminin "başka bir uygulamada aç" akışına yönlendirir.
Future<void> openAttachmentExternally(
  BuildContext context, {
  required String localPath,
  required String mimeType,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final effectiveType =
      (mimeType.isNotEmpty && mimeType != 'application/octet-stream')
          ? mimeType
          : null;
  final result = await OpenFilex.open(localPath, type: effectiveType);
  if (result.type == ResultType.done || !overlay.mounted) return;
  KaydetNotice.show(overlay, message: _openErrorMessage(result.type));
}

String _openErrorMessage(ResultType type) => switch (type) {
  ResultType.noAppToOpen => 'Bu dosya türü için yüklü bir uygulama yok.',
  ResultType.permissionDenied => 'İzin verilmediği için dosya açılamadı.',
  ResultType.fileNotFound => 'Dosya bulunamadı.',
  ResultType.done || ResultType.error => 'Dosya açılamadı.',
};

/// Metin tabanlı bir ekin içeriğini panoya kopyalar (bkz.
/// [AttachmentKind.text]) — dosya tabanlı eklerde platformun güvenilir bir
/// "panoya dosya kopyala" mekanizması olmadığından bu eylem yalnızca metin
/// türlerinde sunulur (bkz. [attachmentMenuItems]).
Future<void> copyAttachmentTextContent(
  BuildContext context, {
  required String localPath,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  try {
    final bytes = await File(localPath).readAsBytes();
    final content = utf8.decode(bytes, allowMalformed: true);
    await Clipboard.setData(ClipboardData(text: content));
    if (!overlay.mounted) return;
    KaydetNotice.show(overlay, message: 'İçerik kopyalandı.');
  } on FileSystemException {
    if (!overlay.mounted) return;
    KaydetNotice.show(overlay, message: 'Dosya okunamadığı için kopyalanamadı.');
  }
}

/// Dosyayı cihaza kalıcı olarak kaydeder — native "farklı kaydet" seçicisini
/// açar (Android'de Storage Access Framework, iOS'ta Dosyalar dışa aktarma),
/// bu yüzden Android'in Scoped Storage kurallarını ihlal etmez. Dosya adı ve
/// uzantısı korunur.
Future<void> saveAttachmentToDevice(
  BuildContext context, {
  required String localPath,
  required String fileName,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  try {
    final ext = p.extension(fileName);
    final cleanExt = ext.startsWith('.') ? ext.substring(1) : ext;
    final saved = await FileSaver.instance.saveAs(
      name: p.basenameWithoutExtension(fileName),
      filePath: localPath,
      fileExtension: cleanExt,
      mimeType: MimeType.other,
    );
    if (!overlay.mounted || saved == null) return;
    KaydetNotice.show(overlay, message: 'Dosya kaydedildi.');
  } catch (_) {
    if (!overlay.mounted) return;
    KaydetNotice.show(overlay, message: 'Dosya kaydedilemedi.');
  }
}

/// Platformun native paylaşım sayfasını (Android Sharesheet / iOS
/// `UIActivityViewController`) doğru MIME type ile açar.
Future<void> shareAttachment(
  BuildContext context, {
  required String localPath,
  required String mimeType,
  required String fileName,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  Rect? origin;
  final box = context.findRenderObject();
  if (box is RenderBox && box.attached && !box.size.isEmpty) {
    origin = box.localToGlobal(Offset.zero) & box.size;
  }
  if (origin == null || origin.isEmpty) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery != null) {
      final size = mediaQuery.size;
      origin = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: 1,
        height: 1,
      );
    }
  }
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(localPath, mimeType: mimeType, name: fileName)],
        sharePositionOrigin: origin,
      ),
    );
  } catch (_) {
    if (!overlay.mounted) return;
    KaydetNotice.show(overlay, message: 'Paylaşım başarısız.');
  }
}

/// Eki, mevcut "sistem Paylaş menüsünden gelen içerik" akışıyla (bkz.
/// `openComposeFromNavigator`) YENİ bir iletiye ekli olarak açar. Dosya
/// tekrar indirilmez: [localPath] zaten önbellekteki/indirilmiş yerel yoldur.
Future<void> sendAttachmentCopy(WidgetRef ref, {required String localPath}) async {
  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) return;
  await openComposeFromNavigator(
    navigator,
    repository: ref.read(mailRepositoryProvider),
    attachmentPaths: [localPath],
  );
}

/// "⋮" popup'ının menü öğeleri — bkz. bellek: kısa seçim listeleri anchored
/// bir popup'ta ([MenuAnchor]), tam ekran bir alttan panelde değil.
List<Widget> attachmentMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required AttachmentRow attachment,
  required String localPath,
  required AttachmentKind kind,
}) {
  return [
    MenuItemButton(
      leadingIcon: const Icon(LucideIcons.externalLink, size: IconSize.sm),
      onPressed: () => openAttachmentExternally(
        context,
        localPath: localPath,
        mimeType: attachment.mimeType,
      ),
      child: const Text('Başka bir uygulamada aç'),
    ),
    if (kind == AttachmentKind.text)
      MenuItemButton(
        leadingIcon: const Icon(LucideIcons.copy, size: IconSize.sm),
        onPressed: () =>
            copyAttachmentTextContent(context, localPath: localPath),
        child: const Text('Kopyala'),
      ),
    MenuItemButton(
      leadingIcon: const Icon(LucideIcons.save, size: IconSize.sm),
      onPressed: () => saveAttachmentToDevice(
        context,
        localPath: localPath,
        fileName: attachment.fileName,
      ),
      child: const Text('Cihaza kaydet'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(LucideIcons.send, size: IconSize.sm),
      onPressed: () => sendAttachmentCopy(ref, localPath: localPath),
      child: const Text('Kopyasını gönder'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(LucideIcons.share2, size: IconSize.sm),
      onPressed: () => shareAttachment(
        context,
        localPath: localPath,
        mimeType: attachment.mimeType,
        fileName: attachment.fileName,
      ),
      child: const Text('Paylaş'),
    ),
  ];
}
