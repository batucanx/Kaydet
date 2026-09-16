import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../theme/tokens.dart';
import '../widgets/kaydet_widgets.dart';

/// Mesaj listesi ve mesaj detayı ekranlarının paylaştığı eylemler.
///
/// `mail_list` ve `mail_detail` feature'ları birbirinin ekranına doğrudan
/// bağımlı olmasın diye (döngüsel import) bu ortak eylemler `ui/core`'a
/// taşınmıştır — ikisi de burayı import eder, birbirini değil.

/// Siler: kalıcı silme gerektiren klasörlerde (Çöp Kutusu/İstenmeyen/
/// Taslaklar) onay ister.
Future<bool> deleteWithConfirmation(
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

  await ref.read(mailRepositoryProvider).deleteMessages(messageIds);
  return true;
}

/// Yazma ekranı, içerikli bir taslağı sormadan otomatik kaydedip geri
/// döndüğünde çağrılır (bkz. `ComposeScreen._saveDraftOnExit`). Ekranın
/// altında kısa bir bildirim gösterir; kullanıcı pişman olursa yanındaki
/// "Sil" eylemiyle taslağı geri alabilir.
void showDraftSavedSnackBar(BuildContext context, WidgetRef ref, int draftId) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('İleti Taslaklara kaydedildi.'),
      action: SnackBarAction(
        label: 'Sil',
        textColor: context.tokens.danger,
        onPressed: () => _confirmDeleteAutosavedDraft(context, ref, draftId),
      ),
    ),
  );
}

/// Taslaklar sunucuya hiç gitmemiştir (bkz. `deleteWithConfirmation`), bu
/// yüzden bu silme de kalıcıdır ve ayrı bir onay ister.
Future<void> _confirmDeleteAutosavedDraft(
  BuildContext context,
  WidgetRef ref,
  int draftId,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Taslağı silmek istediğinize emin misiniz?'),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Hayır',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: 'Evet',
          onConfirm: () => Navigator.of(context).pop(true),
          destructive: true,
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await ref.read(mailRepositoryProvider).deletePermanently([draftId]);
}

/// Klasör seçim sayfası.
Future<SpecialUse?> showFolderPicker(BuildContext context, WidgetRef ref) {
  final mailboxes = ref.read(mailboxesProvider).value ?? const <MailboxRow>[];
  return showModalBottomSheet<SpecialUse>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionHeader('KLASÖRE TAŞI'),
          for (final box in mailboxes.where((m) => m.isSelectable))
            ListTile(
              leading: Icon(folderIcon(box.specialUse), size: IconSize.md),
              title: Text(box.name),
              onTap: () => Navigator.of(context).pop(box.specialUse),
            ),
          const SizedBox(height: Space.sm),
        ],
      ),
    ),
  );
}

/// Etiket seçim sayfası.
Future<String?> showLabelPicker(BuildContext context, WidgetRef ref) {
  final labels = ref.read(labelsProvider).value ?? const <LabelRow>[];
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionHeader('ETİKET EKLE'),
          if (labels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(Space.xxl),
              child: Text('Henüz etiket yok. Ayarlar\'dan ekleyebilirsiniz.'),
            ),
          for (final label in labels)
            ListTile(
              leading: LabelChip(name: label.name, toneIndex: label.toneIndex),
              title: const SizedBox.shrink(),
              onTap: () => Navigator.of(context).pop(label.name),
            ),
          const SizedBox(height: Space.sm),
        ],
      ),
    ),
  );
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
