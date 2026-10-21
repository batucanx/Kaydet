import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../../core/date_format.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'attachment_icon.dart';

/// Tek bir ekin, ekranlardan bağımsız görüntüleme verisi. Hem yazma ekranı
/// (yerel dosyalar) hem de okuma ekranı (sunucu ekleri) kendi ekini bu biçime
/// çevirir; [AttachmentSummary] ve liste sayfası yalnızca bunu bilir.
class AttachmentEntry {
  const AttachmentEntry({
    required this.name,
    this.mimeType = '',
    this.sizeBytes = 0,
    this.localPath,
    this.pending = false,
    this.uploaded = false,
    this.onOpen,
    this.onRemove,
    this.sheetTrailing,
  });

  final String name;
  final String mimeType;
  final int sizeBytes;

  /// Cihazdaki yol. Görsel eklerde küçük resim olarak gösterilir.
  final String? localPath;

  /// Hâlâ hazırlanıyor (indiriliyor/kopyalanıyor): ikon yerine yükleniyor
  /// göstergesi çıkar, açılamaz.
  final bool pending;

  /// Az önce hazır oldu: ikon geçici olarak onay işaretine döner.
  final bool uploaded;

  /// Ekin önizlemesini açar. Verilen `BuildContext` çağrının yapıldığı yerin
  /// (çip ya da liste sayfası) bağlamıdır — önizleme, liste sayfasının ÜSTÜNE
  /// açılsın ve geri dönüşte sayfaya dönülsün diye o bağlamla itilmelidir.
  final void Function(BuildContext context)? onOpen;

  /// Verilirse çipte ve listede "x" ile kaldırılabilir.
  final VoidCallback? onRemove;

  /// Liste sayfasında satırın sonuna konan öğe (ör. "⋮" menüsü). Verilmezse
  /// [onRemove] varsa kaldır düğmesi gösterilir.
  final Widget Function(BuildContext context)? sheetTrailing;

  AttachmentKind get kind =>
      AttachmentType.resolve(mimeType: mimeType, fileName: name);
}

/// Satır içinde en çok kaç ek gösterilir; kalanı "+N ek" ile listeye girer.
const int kAttachmentInlineLimit = 4;

const double _chipHeight = 36;
const double _chipGap = Space.sm;
const double _overflowWidth = 84;

/// [text]'i [maxWidth]'e sığacak biçimde ORTADAN kısaltır ve uzantıyı korur:
/// `1aecf3ec1401151ab3b6385980….png` → `1aecf3ec14…980.png`. Sığıyorsa aynen
/// döner. Düz sondan kesme, uzun karma adlı eklerde türü ve ayırt edici sonu
/// gizler.
@visibleForTesting
String middleEllipsize(
  String text,
  double maxWidth,
  TextStyle style, {
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (text.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return text;

  double measure(String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  if (measure(text) <= maxWidth) return text;

  final chars = text.characters.toList();
  final extension = p.extension(text);
  final extensionLength =
      extension.isNotEmpty && extension.length <= 8
      ? extension.characters.length
      : 0;
  final tailLength = math.min(chars.length - 1, extensionLength + 3);
  final tail = chars.sublist(chars.length - tailLength).join();

  var low = 0;
  var high = chars.length - tailLength - 1;
  var best = 0;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (measure('${chars.take(mid).join()}…$tail') <= maxWidth) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return '${chars.take(best).join()}…$tail';
}

/// Tek satır dosya adı; sığmazsa ortadan kısaltır ([middleEllipsize]).
class AttachmentNameText extends StatelessWidget {
  const AttachmentNameText(this.name, {super.key, this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        middleEllipsize(
          name,
          constraints.maxWidth,
          resolved,
          textScaler: scaler,
          textDirection: direction,
        ),
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Eklerin kompakt özeti: ilk [maxVisible] ek küçük çipler olarak, kalanı tek
/// bir "+N ek" çipinde toplanır; ona dokunmak tüm eklerin listelendiği,
/// her birinin önizlenebildiği bir alt sayfa açar.
///
/// Çip genişliği kullanılabilir genişlikten türetilir (telefonda yan yana 2,
/// geniş ekranda 3-4): ad uzunluğu ne olursa olsun düzen sabit kalır, ek
/// sayısı ne olursa olsun yükseklik sınırlıdır.
///
/// Liste sayfası CANLIDIR: [entries] değişince (ek eklendi/kaldırıldı/hazır
/// oldu) açık sayfa da güncellenir.
class AttachmentSummary extends StatefulWidget {
  const AttachmentSummary({
    super.key,
    required this.entries,
    this.maxVisible = kAttachmentInlineLimit,
    this.sheetActionsBuilder,
  });

  final List<AttachmentEntry> entries;
  final int maxVisible;

  /// Liste sayfasının başlığındaki ek eylemler (ör. "Kaydet").
  final List<Widget> Function(BuildContext sheetContext)? sheetActionsBuilder;

  @override
  State<AttachmentSummary> createState() => _AttachmentSummaryState();
}

class _AttachmentSummaryState extends State<AttachmentSummary> {
  late final ValueNotifier<List<AttachmentEntry>> _live = ValueNotifier(
    widget.entries,
  );

  @override
  void didUpdateWidget(AttachmentSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Yapı (build) sırasında başka bir ağaca (açık sayfa) bildirim
    // gönderilemez; kare sonrasına bırakılır.
    final latest = widget.entries;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _live.value = latest;
    });
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  double _chipMaxWidth(double available) {
    if (available >= 720) {
      return math
          .min(240, (available - _overflowWidth - 4 * _chipGap) / 4)
          .toDouble();
    }
    final columns = available >= 480 ? 3 : 2;
    return (available - _chipGap * (columns - 1)) / columns;
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    if (entries.isEmpty) return const SizedBox.shrink();
    final visible = entries.take(widget.maxVisible).toList();
    final hidden = entries.skip(widget.maxVisible).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final chipMax = _chipMaxWidth(constraints.maxWidth);
        return Wrap(
          spacing: _chipGap,
          runSpacing: Space.sm - 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in visible)
              _AttachmentPill(entry: entry, maxWidth: chipMax),
            if (hidden.isNotEmpty)
              _OverflowPill(
                count: hidden.length,
                hasPending: hidden.any((e) => e.pending),
                onTap: () => showAttachmentListSheet(
                  context,
                  entries: _live,
                  actionsBuilder: widget.sheetActionsBuilder,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Ek çipinin/satırının başındaki görsel: yükleniyor göstergesi, onay işareti,
/// görsel eklerde küçük resim, aksi hâlde tür ikonu.
class _EntryLeading extends StatelessWidget {
  const _EntryLeading({required this.entry, required this.size});

  final AttachmentEntry entry;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (entry.pending) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: SizedBox(
            width: size * 0.7,
            height: size * 0.7,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: t.textSecondary,
            ),
          ),
        ),
      );
    }
    if (entry.uploaded) {
      return Icon(LucideIcons.checkCircle, size: size, color: t.success);
    }
    final typeIcon = AttachmentTypeIcon(
      kind: entry.kind,
      fileName: entry.name,
      mimeType: entry.mimeType,
      size: size,
    );
    final path = entry.localPath;
    if (entry.kind != AttachmentKind.image || path == null) return typeIcon;

    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.xs),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: pixels,
        gaplessPlayback: true,
        // Dosya yok/bozuk: sessizce tür ikonuna dön.
        errorBuilder: (context, error, stackTrace) => typeIcon,
      ),
    );
  }
}

class _AttachmentPill extends StatelessWidget {
  const _AttachmentPill({required this.entry, required this.maxWidth});

  final AttachmentEntry entry;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final onOpen = entry.onOpen;
    final onRemove = entry.onRemove;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Tooltip(
        // Kısaltılan ad uzun basınca tam görünür.
        message: entry.name,
        child: Material(
          color: t.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: BorderSide(color: t.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: entry.pending || onOpen == null
                ? null
                : () => onOpen(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _chipHeight),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: Space.sm),
                  _EntryLeading(entry: entry, size: IconSize.md),
                  const SizedBox(width: Space.sm - 2),
                  Flexible(
                    child: AttachmentNameText(
                      entry.name,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  if (onRemove != null)
                    IconButton(
                      icon: const Icon(LucideIcons.x, size: IconSize.sm),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: _chipHeight - 4,
                        minHeight: _chipHeight - 4,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Kaldır',
                      onPressed: onRemove,
                    )
                  else
                    const SizedBox(width: Space.md),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OverflowPill extends StatelessWidget {
  const _OverflowPill({
    required this.count,
    required this.hasPending,
    required this.onTap,
  });

  final int count;
  final bool hasPending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: '$count ek daha, tümünü göster',
      child: Material(
        color: t.accentSubtle,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _chipHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPending) ...[
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: t.accent,
                      ),
                    ),
                    const SizedBox(width: Space.xs + 2),
                  ],
                  Text(
                    '+$count ek',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: t.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tüm eklerin listelendiği alt sayfa: her satırda tür ikonu/küçük resim, ad,
/// tür · boyut ve satıra dokununca önizleme. [entries] canlıdır; liste
/// boşalırsa (hepsi kaldırıldı) sayfa kendiliğinden kapanır.
Future<void> showAttachmentListSheet(
  BuildContext context, {
  required ValueListenable<List<AttachmentEntry>> entries,
  List<Widget> Function(BuildContext sheetContext)? actionsBuilder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: AnimationStyle(
      duration: context.motion(Motion.base),
      reverseDuration: context.motion(Motion.fast),
      curve: Motion.standard,
    ),
    builder: (sheetContext) => _AttachmentListSheet(
      entries: entries,
      actionsBuilder: actionsBuilder,
    ),
  );
}

class _AttachmentListSheet extends StatelessWidget {
  const _AttachmentListSheet({required this.entries, this.actionsBuilder});

  final ValueListenable<List<AttachmentEntry>> entries;
  final List<Widget> Function(BuildContext sheetContext)? actionsBuilder;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ValueListenableBuilder<List<AttachmentEntry>>(
          valueListenable: entries,
          builder: (context, list, _) {
            if (list.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).maybePop();
              });
              return const SizedBox(height: Space.xxxl);
            }
            final totalBytes = list.fold<int>(0, (sum, e) => sum + e.sizeBytes);
            final summary = totalBytes > 0
                ? '${list.length} ek · ${formatBytes(totalBytes)}'
                : '${list.length} ek';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.xs,
                    Space.xs,
                    Space.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ekler',
                              style: AppText.titleLarge.copyWith(
                                color: t.textPrimary,
                              ),
                            ),
                            Text(
                              summary,
                              style: textTheme.labelSmall?.copyWith(
                                color: t.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...?actionsBuilder?.call(context),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      indent: Space.lg + 36 + Space.md,
                      color: t.divider,
                    ),
                    itemBuilder: (context, index) =>
                        _AttachmentListRow(entry: list[index]),
                  ),
                ),
                const SizedBox(height: Space.sm),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AttachmentListRow extends StatelessWidget {
  const _AttachmentListRow({required this.entry});

  final AttachmentEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final onOpen = entry.onOpen;
    final label = AttachmentType.label(entry.name, entry.mimeType);
    final subtitle = entry.pending
        ? 'Hazırlanıyor…'
        : (entry.sizeBytes > 0
              ? '$label · ${formatBytes(entry.sizeBytes)}'
              : label);
    final trailing =
        entry.sheetTrailing?.call(context) ??
        (entry.onRemove != null
            ? IconButton(
                icon: const Icon(LucideIcons.x, size: IconSize.md),
                tooltip: 'Kaldır',
                onPressed: entry.onRemove,
              )
            : null);
    return InkWell(
      onTap: entry.pending || onOpen == null ? null : () => onOpen(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Dimens.listRowMinHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.xs,
            Space.xs,
            Space.xs,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: Center(child: _EntryLeading(entry: entry, size: 32)),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AttachmentNameText(
                      entry.name,
                      style: textTheme.bodyMedium?.copyWith(
                        color: t.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: t.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
