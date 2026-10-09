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

/// Gelen Kutusuna geri yükler: Çöp Kutusu'nda swipe-sağ jestinin (bkz.
/// `_SwipeRowState` — normal klasörlerde aynı jest arşivler) TEK yolu.
/// `archiveMessages` ile birebir aynı iyimser + "Geri al" akışını izler.
Future<void> restoreMessagesToInbox(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (messageIds.isEmpty) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  if (!await confirmJunkRestore(context, ref, messageIds)) return;
  final handle = await ref
      .read(mailRepositoryProvider)
      .restoreToInbox(messageIds, undoWindow: ref.read(mailUndoWindowProvider));
  if (handle == null || !overlay.mounted) return;
  _showUndoNotice(
    overlay,
    message: messageIds.length == 1
        ? 'İleti Gelen Kutusuna taşındı'
        : '${messageIds.length} ileti Gelen Kutusuna taşındı',
    handle: handle,
    bottomInset: bottomInset,
  );
}

/// İstenmeyen'deki bir ileti Gelen Kutusu'na alınırken göndericisi hâlâ "istenmeyen" listesindeyse
/// sorar: liste durursa sonraki tarama iletiyi yeniden İstenmeyen'e iterdi. "İstenmeyen Durumunu
/// Kaldır" göndericiyi listeden çıkarıp taşımaya izin verir; "Vazgeç" hiçbir şeye dokunmaz (`false`).
/// Soru gerekmiyorsa doğrudan `true`.
Future<bool> confirmJunkRestore(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds,
) async {
  final blocking = ref.read(blockedSenderRepositoryProvider);
  if (!await blocking.hasListedSenderInJunk(messageIds)) return true;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('İstenmeyen durumu kaldırılsın mı?'),
      content: const Text(
        'Bu gönderici istenmeyen olarak işaretlenmiş. Bu göndericinin '
        'istenmeyen durumunu kaldırmak istiyor musunuz?',
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Vazgeç',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: 'İstenmeyen Durumunu Kaldır',
          onConfirm: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await blocking.unlistSendersOf(messageIds);
  return true;
}

/// "İstenmeyen olarak işaretle": gönderici listeye girer, ileti İstenmeyen'e taşınır (zaten
/// oradaysa yerinde kalır, yalnızca gönderici listelenir). Dönüş: ileti klasöründen ayrıldı mı.
Future<bool> markMessagesAsSpam(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (messageIds.isEmpty) return false;
  final overlay = Overlay.of(context, rootOverlay: true);
  final moved = await ref
      .read(blockedSenderRepositoryProvider)
      .markSpam(messageIds);
  if (overlay.mounted) {
    final one = messageIds.length == 1;
    KaydetNotice.show(
      overlay,
      message: moved
          ? (one
                ? 'İleti İstenmeyen klasörüne taşındı'
                : '${messageIds.length} ileti İstenmeyen klasörüne taşındı')
          : (one
                ? 'Gönderici istenmeyen olarak işaretlendi'
                : 'Gönderenler istenmeyen olarak işaretlendi'),
      bottomInset: bottomInset,
    );
  }
  return moved;
}

/// "İstenmeyen değil olarak işaretle": gönderici listeden çıkar; İstenmeyen'deki ileti Gelen
/// Kutusu'na döner ("Geri al" ile geri alınabilir). Dönüş: ileti klasöründen ayrıldı mı.
Future<bool> markMessagesAsNotSpam(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds, {
  double bottomInset = 0,
}) async {
  if (messageIds.isEmpty) return false;
  final overlay = Overlay.of(context, rootOverlay: true);
  final result = await ref
      .read(blockedSenderRepositoryProvider)
      .markNotSpam(messageIds, undoWindow: ref.read(mailUndoWindowProvider));
  if (!overlay.mounted) return result.restored;
  final one = messageIds.length == 1;
  final message = result.restored
      ? (one
            ? 'İleti Gelen Kutusuna taşındı, gönderici istenmeyen değil'
            : '${messageIds.length} ileti Gelen Kutusuna taşındı, '
                  'gönderenler istenmeyen değil')
      : (one
            ? 'Gönderici istenmeyen değil olarak işaretlendi'
            : 'Gönderenler istenmeyen değil olarak işaretlendi');
  final handle = result.handle;
  if (handle != null) {
    _showUndoNotice(
      overlay,
      message: message,
      handle: handle,
      bottomInset: bottomInset,
    );
  } else {
    KaydetNotice.show(overlay, message: message, bottomInset: bottomInset);
  }
  return result.restored;
}

/// Seçili klasöre taşır. İstenmeyen'e taşımak "İstenmeyen olarak işaretle"dir (gönderici de
/// listelenir); İstenmeyen'den Gelen Kutusu'na taşımak listedeki göndericiyi önce sorar (bkz.
/// [confirmJunkRestore]). Dönüş: taşıma yapıldı mı (`false`: kullanıcı vazgeçti ya da taşınamadı).
Future<bool> moveMessagesToFolder(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds,
  MailboxRow target,
) async {
  if (messageIds.isEmpty) return false;
  if (target.specialUse == SpecialUse.junk) {
    await markMessagesAsSpam(context, ref, messageIds);
    return true;
  }
  if (target.specialUse == SpecialUse.inbox &&
      !await confirmJunkRestore(context, ref, messageIds)) {
    return false;
  }
  await ref
      .read(mailRepositoryProvider)
      .moveToFolder(messageIds: messageIds, targetMailboxId: target.id);
  return true;
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

  // Tüm Hesaplar görünümünde de birleşik klasörün türü geçerlidir.
  final use = ref.read(currentSpecialUseProvider);
  final isDrafts = use == SpecialUse.drafts;
  // Taslaklar sunucuya hiç gitmemiştir (bkz. `MailRepository.moveToMailbox`):
  // Taslaklar klasöründe silme, Çöp Kutusu'na taşınacak bir sunucu kaydı
  // olmadığı için doğrudan ve kalıcıdır. `FolderMapping.deleteIsPermanent`
  // yalnızca Çöp Kutusu/İstenmeyen'i kalıcı sayar; Taslaklar'ı da eklemezsek
  // kullanıcı bir taslağı tek dokunuşla, hiç onay istenmeden geri dönüşsüz
  // kaybeder.
  final isPermanent =
      isDrafts || (use != null && FolderMapping.deleteIsPermanent(use));
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

/// Menünün, seçili iletiler tek bir hesaba indirgenemediğinde (Tüm Hesaplar
/// görünümünde farklı hesaplardan çoklu seçim) gösterdiği tek, pasif öğe:
/// klasör ve etiketler hesaba özgüdür, karışık bir seçime uygulanamaz.
List<Widget> _mixedAccountsMenu() => const [
  MenuItemButton(
    onPressed: null,
    child: Text('Farklı hesaplardan iletiler seçili'),
  ),
];

/// "Taşı" popup'ının menü öğeleri — bkz. bellek: kısa seçim listeleri tam
/// ekranı kaplayan bir alttan panel yerine anında açılan bir popup'ta.
///
/// [accountId] verilirse o hesabın klasörleri listelenir (Tüm Hesaplar
/// görünümünde iletinin KENDİ hesabı); verilmezse etkin hesabınkiler.
/// [excludeMailboxId] listeden çıkarılacak (iletinin zaten içinde olduğu)
/// klasördür; verilmezse görüntülenen klasör. [mixedAccounts] `true` ise seçim
/// birden çok hesaba yayılıyor demektir ve yalnızca pasif bir bilgi öğesi döner.
List<Widget> folderMenuItems(
  WidgetRef ref,
  ValueChanged<MailboxRow> onSelected, {
  int? accountId,
  int? excludeMailboxId,
  bool mixedAccounts = false,
}) {
  if (mixedAccounts) return _mixedAccountsMenu();
  final targetAccountId = accountId ?? ref.watch(accountIdProvider);
  final tree = targetAccountId == null
      ? const <FolderTreeNode>[]
      : ref.watch(folderTreeForAccountProvider(targetAccountId));
  final currentMailboxId =
      excludeMailboxId ?? ref.watch(currentMailboxProvider)?.id;
  return [
    for (final node in tree)
      // Taslaklar yalnızca yazma ekranından oluşur; diğer mobil istemciler
      // gibi bir ileti buraya taşınamaz.
      if (node.mailbox.id != currentMailboxId &&
          node.mailbox.specialUse != SpecialUse.drafts)
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

/// "Etiket" popup'ının menü öğeleri. [accountId]/[mixedAccounts] için bkz.
/// [folderMenuItems].
List<Widget> labelMenuItems(
  BuildContext context,
  WidgetRef ref,
  ValueChanged<String> onSelected, {
  int? accountId,
  bool mixedAccounts = false,
  Set<String> applied = const {},
  ValueChanged<String>? onRemoved,
}) {
  if (mixedAccounts) return _mixedAccountsMenu();
  final t = context.tokens;
  final labels = accountId == null
      ? ref.read(labelsProvider).value ?? const <LabelRow>[]
      : ref.watch(labelsForAccountProvider(accountId)).value ??
            const <LabelRow>[];
  if (labels.isEmpty) {
    return const [
      MenuItemButton(onPressed: null, child: Text('Henüz etiket yok')),
    ];
  }
  return [
    for (final label in labels)
      // Uygulanmış etikete dokunmak onu kaldırır (onay işaretiyle gösterilir).
      if (onRemoved != null && applied.contains(label.name))
        MenuItemButton(
          leadingIcon: Icon(
            LucideIcons.tag,
            size: IconSize.sm,
            color: t.toneAt(label.toneIndex).foreground,
          ),
          trailingIcon: const Icon(LucideIcons.check, size: IconSize.sm),
          onPressed: () => onRemoved(label.name),
          child: Text(label.name),
        )
      else
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
