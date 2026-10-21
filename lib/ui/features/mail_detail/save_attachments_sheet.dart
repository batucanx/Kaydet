import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/date_format.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../data/services/device_downloads.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../core/actions/attachment_batch_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/attachment_icon.dart';
import '../../core/widgets/kaydet_notice.dart';

/// Bir iletinin eklerini TEK seferde cihaza kaydeden alt sayfa (Outlook'un
/// "Ekleri kaydet" sayfası): her ekin yanında bir onay kutusu (başta hepsi
/// seçili), sağ üstte "Kaydet".
///
/// "Kaydet"e basınca seçili ekler sırayla indirilir ve cihaza yazılır (bkz.
/// [saveAttachmentsToDevice]); sayfa sürerken ilerlemeyi gösterir, bitince
/// kapanır ve sonuç [KaydetNotice] ile bildirilir. Sonuç bildirimi sayfa
/// kapatılsa bile (iş sürer) kök `Overlay`de gösterilir.
///
/// [resolvePath], [downloads] ve [saveAs]/[share] yalnızca testlerde
/// değiştirilir; varsayılan davranış gerçek depo ve platformdur.
Future<void> showSaveAttachmentsSheet(
  BuildContext context, {
  required List<AttachmentRow> attachments,
  Future<Result<String>> Function(AttachmentRow attachment)? resolvePath,
  DeviceDownloads downloads = const DeviceDownloads(),
  SaveAsFn? saveAs,
  ShareFilesFn? share,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  // iPad'de paylaşım sayfası bir çapa ister; sayfa açılmadan ÖNCE, çağıran
  // düğmenin (varsa) konumundan alınır.
  Rect? shareOrigin;
  final box = context.findRenderObject();
  if (box is RenderBox && box.attached && !box.size.isEmpty) {
    shareOrigin = box.localToGlobal(Offset.zero) & box.size;
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: AnimationStyle(
      duration: context.motion(Motion.base),
      reverseDuration: context.motion(Motion.fast),
      curve: Motion.standard,
    ),
    builder: (_) => SaveAttachmentsSheet(
      attachments: attachments,
      overlay: overlay,
      shareOrigin: shareOrigin,
      resolvePath: resolvePath,
      downloads: downloads,
      saveAs: saveAs,
      share: share,
    ),
  );
}

class SaveAttachmentsSheet extends ConsumerStatefulWidget {
  const SaveAttachmentsSheet({
    super.key,
    required this.attachments,
    required this.overlay,
    this.shareOrigin,
    this.resolvePath,
    this.downloads = const DeviceDownloads(),
    this.saveAs,
    this.share,
  });

  final List<AttachmentRow> attachments;
  final OverlayState overlay;
  final Rect? shareOrigin;
  final Future<Result<String>> Function(AttachmentRow attachment)? resolvePath;
  final DeviceDownloads downloads;
  final SaveAsFn? saveAs;
  final ShareFilesFn? share;

  @override
  ConsumerState<SaveAttachmentsSheet> createState() =>
      _SaveAttachmentsSheetState();
}

class _SaveAttachmentsSheetState extends ConsumerState<SaveAttachmentsSheet> {
  late final Set<int> _selected = {for (final a in widget.attachments) a.id};
  bool _saving = false;
  int _done = 0;
  int _total = 0;

  bool get _allSelected => _selected.length == widget.attachments.length;

  void _toggle(AttachmentRow attachment) {
    if (_saving) return;
    setState(() {
      if (!_selected.remove(attachment.id)) _selected.add(attachment.id);
    });
  }

  void _toggleAll() {
    if (_saving) return;
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.attachments.map((a) => a.id));
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _selected.isEmpty) return;
    // Listedeki (şeritteki) sırayı koru.
    final chosen = [
      for (final a in widget.attachments)
        if (_selected.contains(a.id)) a,
    ];

    // İş, sayfa kapatılsa bile sürer: bu yüzden `ref` ve `context` iş
    // BİTENE kadar tutulmaz — gereken her şey burada bir kez alınır.
    final overlay = widget.overlay;
    final navigator = Navigator.of(context);
    final custom = widget.resolvePath;
    final repository = custom == null ? ref.read(mailRepositoryProvider) : null;
    final Future<Result<String>> Function(AttachmentRow) resolve =
        custom ?? (a) => repository!.downloadAttachment(a.id);

    setState(() {
      _saving = true;
      _done = 0;
      _total = chosen.length;
    });

    final report = await saveAttachmentsToDevice(
      attachments: chosen,
      resolvePath: resolve,
      downloads: widget.downloads,
      shareOrigin: widget.shareOrigin,
      saveAs: widget.saveAs,
      share: widget.share,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
    );

    if (mounted) navigator.pop();
    final message = report.message;
    if (message != null && overlay.mounted) {
      KaydetNotice.show(overlay, message: message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final canSaveDirectly = widget.downloads.canSaveDirectly;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.xs,
                Space.sm,
                Space.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ekleri kaydet',
                          style: AppText.titleLarge.copyWith(
                            color: t.textPrimary,
                          ),
                        ),
                        if (canSaveDirectly)
                          Text(
                            'İndirilenler/${DeviceDownloads.folderName} '
                            'klasörüne kaydedilir',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_saving)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.md),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: IconSize.sm,
                            height: IconSize.sm,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: t.accent,
                            ),
                          ),
                          const SizedBox(width: Space.sm),
                          Text(
                            '$_done/$_total',
                            style: theme.textTheme.labelMedium,
                          ),
                        ],
                      ),
                    )
                  else
                    TextButton(
                      onPressed: _selected.isEmpty ? null : _save,
                      child: const Text('Kaydet'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (widget.attachments.length > 1)
                    _SelectAllRow(
                      value: _allSelected
                          ? true
                          : (_selected.isEmpty ? false : null),
                      enabled: !_saving,
                      onTap: _toggleAll,
                    ),
                  for (final attachment in widget.attachments)
                    _AttachmentSelectRow(
                      attachment: attachment,
                      selected: _selected.contains(attachment.id),
                      enabled: !_saving,
                      onTap: () => _toggle(attachment),
                    ),
                  const SizedBox(height: Space.sm),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectAllRow extends StatelessWidget {
  const _SelectAllRow({
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final bool? value;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Tümünü seç',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: t.textSecondary),
              ),
            ),
            Checkbox(
              tristate: true,
              value: value,
              onChanged: enabled ? (_) => onTap() : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentSelectRow extends StatelessWidget {
  const _AttachmentSelectRow({
    required this.attachment,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final AttachmentRow attachment;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final kind = AttachmentType.resolve(
      mimeType: attachment.mimeType,
      fileName: attachment.fileName,
    );
    return InkWell(
      onTap: enabled ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Dimens.listRowMinHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.xs,
          ),
          child: Row(
            children: [
              AttachmentTypeIcon(
                kind: kind,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                size: IconSize.xl,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      attachment.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: t.textPrimary,
                      ),
                    ),
                    Text(
                      formatBytes(attachment.sizeBytes),
                      style: textTheme.labelSmall?.copyWith(
                        color: t.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Checkbox(
                value: selected,
                onChanged: enabled ? (_) => onTap() : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
