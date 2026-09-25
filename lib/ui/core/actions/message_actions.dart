import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../data/repositories/mail_repository.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../../core/result.dart';
import '../theme/tokens.dart';
import '../widgets/kaydet_notice.dart';
import '../widgets/kaydet_widgets.dart';

/// Mesaj listesi ve mesaj detayı ekranlarının paylaştığı eylemler.
///
/// `mail_list` ve `mail_detail` feature'ları birbirinin ekranına doğrudan
/// bağımlı olmasın diye (döngüsel import) bu ortak eylemler `ui/core`'a
/// taşınmıştır — ikisi de burayı import eder, birbirini değil.

/// Bildirimin ekranda kalma süresi — geri alma penceresinden
/// (bkz. `mailUndoWindowProvider`, 6 sn) kısa tutulur ki görünen "Geri al"
/// düğmesi her zaman hâlâ geçerli olsun. Sunucu işlemi pencere boyunca
/// bekletilir; "Geri al" bu pencerede gerçek sunucu durumunu korur.
const Duration _undoNoticeDuration = Duration(seconds: 5);

/// Arşivle: swipe, seçim çubuğu ve detay ekranının ortak, TEK yolu.
///
/// İleti listeden hemen çıkar (iyimser), sunucu taşıması kuyrukta işlenir;
/// başarısız olursa iletiler geri yüklenir ve kullanıcı bilgilendirilir
/// (bkz. [showMailActionFailure]).
Future<void> archiveMessages(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (messageIds.isEmpty) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  final handle = await ref
      .read(mailRepositoryProvider)
      .archive(messageIds, undoWindow: ref.read(mailUndoWindowProvider));
  if (handle == null || !overlay.mounted) return;
  _showUndoNotice(
    overlay,
    message: messageIds.length == 1
        ? 'İleti arşivlendi'
        : '${messageIds.length} ileti arşivlendi',
    handle: handle,
    bottomInset: bottomInset,
  );
}

/// Siler: kalıcı silme gerektiren klasörlerde (Çöp Kutusu/İstenmeyen/
/// Taslaklar) onay ister; Çöp Kutusu'na taşıma "Geri al" ile geri alınabilir.
Future<bool> deleteWithConfirmation(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (!await confirmDelete(context, ref, messageIds)) return false;
  if (!context.mounted) return false;
  await deleteMessagesWithUndo(context, ref, messageIds, bottomInset: bottomInset);
  return true;
}

/// Onay istemeden siler (onay çağıranda alınmıştır — bkz. [confirmDelete]);
/// Çöp Kutusu'na taşıma "Geri al" ile geri alınabilir.
Future<void> deleteMessagesWithUndo(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (messageIds.isEmpty) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  final handle = await ref
      .read(mailRepositoryProvider)
      .deleteMessages(messageIds, undoWindow: ref.read(mailUndoWindowProvider));
  if (handle == null || !overlay.mounted) return;
  _showUndoNotice(
    overlay,
    message: messageIds.length == 1
        ? 'İleti silindi'
        : '${messageIds.length} ileti silindi',
    handle: handle,
    bottomInset: bottomInset,
  );
}

/// Silmeden önce gerekiyorsa (kalıcı silme + ayar açık) onay ister. Onay
/// gerekmiyorsa ya da verildiyse `true`.
Future<bool> confirmDelete(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds,
) async {
  if (messageIds.isEmpty) return false;

  final mailbox = ref.read(currentMailboxProvider);
  final isDrafts = mailbox?.specialUse == SpecialUse.drafts;
  // Taslaklar sunucuya hiç gitmemiştir (bkz. `MailRepository.moveToMailbox`):
  // Taslaklar klasöründe silme, Çöp Kutusu'na taşınacak bir sunucu kaydı
  // olmadığı için doğrudan ve kalıcıdır. `FolderMapping.deleteIsPermanent`
  // yalnızca Çöp Kutusu/İstenmeyen'i kalıcı sayar; Taslaklar'ı da eklemezsek
  // kullanıcı bir taslağı tek dokunuşla, hiç onay istenmeden geri dönüşsüz
  // kaybeder.
  final isPermanent =
      isDrafts ||
      (mailbox != null && FolderMapping.deleteIsPermanent(mailbox.specialUse));
  final askFirst = ref.read(settingsProvider).confirmBeforeDelete;

  if (isPermanent && askFirst) {
    final count = messageIds.length;
    final content = isDrafts
        ? (count == 1
              ? 'Bu taslak kalıcı olarak silinecek. Bu işlem geri alınamaz.'
              : '$count taslak kalıcı olarak silinecek. '
                    'Bu işlem geri alınamaz.')
        : (count == 1
              ? 'Bu ileti sunucudan da kalıcı olarak silinecek. '
                    'Bu işlem geri alınamaz.'
              : '$count ileti sunucudan da kalıcı olarak silinecek. '
                    'Bu işlem geri alınamaz.');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kalıcı olarak silinsin mi?'),
        content: Text(content),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(false),
            confirmLabel: 'Kalıcı olarak sil',
            onConfirm: () => Navigator.of(context).pop(true),
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
  }
  return true;
}

void _showUndoNotice(
  OverlayState overlay, {
  required String message,
  required MailActionHandle handle,
  required double bottomInset,
}) {
  KaydetNotice.show(
    overlay,
    message: message,
    actionLabel: 'Geri al',
    bottomInset: bottomInset,
    duration: _undoNoticeDuration,
    onAction: () => unawaited(_undo(overlay, handle, bottomInset)),
  );
}

Future<void> _undo(
  OverlayState overlay,
  MailActionHandle handle,
  double bottomInset,
) async {
  final restored = await handle.undo();
  if (restored || !overlay.mounted) return;
  KaydetNotice.show(
    overlay,
    message: 'İşlem geri alınamadı.',
    bottomInset: bottomInset,
  );
}

/// Sunucuda başarısız olup yerelde geri alınan arşivle/sil/taşı eylemini
/// kullanıcıya bildirir (bkz. `MailRepository.actionFailures`).
void showMailActionFailure(OverlayState overlay, MailActionFailure event) {
  final plural = event.count > 1;
  final subject = plural ? 'İletiler' : 'İleti';
  final message = switch ((event.kind, event.failure)) {
    (MailActionKind.archive, MailboxNotFoundFailure()) =>
      'Arşiv klasörü bulunamadı veya oluşturulamadı. '
          '$subject geri getirildi.',
    (MailActionKind.archive, _) =>
      '$subject arşivlenemedi. Lütfen tekrar deneyin.',
    (MailActionKind.delete, _) => '$subject silinemedi. Lütfen tekrar deneyin.',
    (MailActionKind.move, _) => '$subject taşınamadı. Lütfen tekrar deneyin.',
  };
  KaydetNotice.show(overlay, message: message);
}

/// "Taşı" popup'ının menü öğeleri — bkz. bellek: kısa seçim listeleri tam
/// ekranı kaplayan bir alttan panel yerine anında açılan bir popup'ta.
List<Widget> folderMenuItems(
  WidgetRef ref,
  ValueChanged<MailboxRow> onSelected,
) {
  final accountId = ref.watch(accountIdProvider);
  final tree = accountId == null
      ? const <FolderTreeNode>[]
      : ref.watch(folderTreeForAccountProvider(accountId));
  final currentMailboxId = ref.watch(currentMailboxProvider)?.id;
  return [
    for (final node in tree)
      if (node.mailbox.id != currentMailboxId)
        MenuItemButton(
          leadingIcon: Icon(
            folderIcon(node.mailbox.specialUse),
            size: IconSize.sm,
          ),
          onPressed: () => onSelected(node.mailbox),
          child: Padding(
            padding: EdgeInsets.only(left: node.depth * Space.lg),
            child: Text(node.mailbox.name),
          ),
        ),
  ];
}

/// "Etiket" popup'ının menü öğeleri.
List<Widget> labelMenuItems(
  BuildContext context,
  WidgetRef ref,
  ValueChanged<String> onSelected,
) {
  final t = context.tokens;
  final labels = ref.read(labelsProvider).value ?? const <LabelRow>[];
  if (labels.isEmpty) {
    return const [
      MenuItemButton(onPressed: null, child: Text('Henüz etiket yok')),
    ];
  }
  return [
    for (final label in labels)
      MenuItemButton(
        leadingIcon: Icon(
          LucideIcons.tag,
          size: IconSize.sm,
          color: t.toneAt(label.toneIndex).foreground,
        ),
        onPressed: () => onSelected(label.name),
        child: Text(label.name),
      ),
  ];
}

/// Klasör türüne göre ikon.
IconData folderIcon(SpecialUse use) => switch (use) {
  SpecialUse.inbox => LucideIcons.inbox,
  SpecialUse.sent => LucideIcons.send,
  SpecialUse.drafts => LucideIcons.fileText,
  SpecialUse.trash => LucideIcons.trash2,
  SpecialUse.junk => LucideIcons.octagonAlert,
  SpecialUse.archive => LucideIcons.archive,
  SpecialUse.custom => LucideIcons.folder,
};
