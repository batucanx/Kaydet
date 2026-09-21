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

/// "Taşı" popup'ının menü öğeleri — bkz. bellek: kısa seçim listeleri tam
/// ekranı kaplayan bir alttan panel yerine anında açılan bir popup'ta.
List<Widget> folderMenuItems(
  WidgetRef ref,
  ValueChanged<SpecialUse> onSelected,
) {
  final mailboxes = ref.read(mailboxesProvider).value ?? const <MailboxRow>[];
  return [
    for (final box in mailboxes.where((m) => m.isSelectable))
      MenuItemButton(
        leadingIcon: Icon(folderIcon(box.specialUse), size: IconSize.sm),
        onPressed: () => onSelected(box.specialUse),
        child: Text(box.name),
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
