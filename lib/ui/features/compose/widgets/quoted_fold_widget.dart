import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/tokens.dart';
import 'compose_image_embed_builder.dart';
import 'quoted_html_view.dart';

/// Yanıtlanan, tümü yanıtlanan veya iletilen iletilerde alıntılanan önceki iletiyi
/// katlanmış (`···`) olarak gösteren ve tıklandığında açıp kapatan bileşen.
class QuotedFoldWidget extends StatelessWidget {
  const QuotedFoldWidget({
    super.key,
    required this.isExpanded,
    required this.onToggle,
    required this.onRemove,
    this.controller,
    this.focusNode,
    this.headerText = '',
    this.fallbackText = '',
    this.customStyleBuilder,
    this.quotedHtml,
    this.onHtmlUnavailable,
    this.onHtmlChanged,
  });

  /// Kullanıcı HTML alıntıyı düzenlediğinde güncel HTML ile çağrılır.
  final ValueChanged<String>? onHtmlChanged;

  /// Orijinal HTML; verilirse açık alıntı WebView'da birebir gösterilir.
  final String? quotedHtml;
  final VoidCallback? onHtmlUnavailable;

  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  final QuillController? controller;
  final FocusNode? focusNode;
  final String headerText;
  final String fallbackText;
  final TextStyle Function(Attribute)? customStyleBuilder;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (!isExpanded) {
      // Katlanmış durum: Web ve masaüstündekiyle birebir üç nokta (...) hap düğmesi
      return Padding(
        padding: const EdgeInsets.only(
          left: Space.lg,
          right: Space.lg,
          top: Space.xs,
          bottom: Space.md,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: 'Alıntılanan metni göster',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('quoted_fold_toggle_button'),
                onTap: onToggle,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: t.isDark
                          ? const Color(0xFF475569)
                          : const Color(0xFFCBD5E1),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    '···',
                    style: TextStyle(
                      color: t.isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Açık durum: Solunda alıntı çizgisi olan tam biçimli alıntı görünümü
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Üst araç satırı: Gizleme hapı, başlık, kapatma ve kaldırma düğmeleri
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Row(
            children: [
              Tooltip(
                message: 'Alıntılanan metni gizle',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('quoted_fold_collapse_pill'),
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: t.isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: t.isDark
                              ? const Color(0xFF475569)
                              : const Color(0xFFCBD5E1),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        '···',
                        style: TextStyle(
                          color: t.isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.messageSquareQuote,
                      size: 14,
                      color: t.textSecondary,
                    ),
                    const SizedBox(width: Space.xs),
                    Flexible(
                      child: Text(
                        'Alıntılanan metin',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: t.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('quoted_fold_collapse_icon'),
                icon: Icon(
                  LucideIcons.chevronUp,
                  size: 18,
                  color: t.textSecondary,
                ),
                tooltip: 'Alıntıyı gizle',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onToggle,
              ),
              IconButton(
                key: const ValueKey('quoted_fold_remove_icon'),
                icon: Icon(
                  LucideIcons.trash2,
                  size: 16,
                  color: t.danger,
                ),
                tooltip: 'Alıntıyı kaldır',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.xs),

        // Alıntılanan içerik kutusu (solunda dikey alıntı çizgisi ile)
        Container(
          margin: const EdgeInsets.only(
            left: Space.lg,
            right: Space.lg,
            bottom: Space.lg,
          ),
          padding: const EdgeInsets.only(left: Space.md, top: Space.xs),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: t.isDark
                    ? const Color(0xFF475569)
                    : const Color(0xFFCBD5E1),
                width: 3,
              ),
            ),
          ),
          child: (quotedHtml != null && onHtmlUnavailable != null)
              ? QuotedHtmlView(
                  key: const ValueKey('quoted_html_view'),
                  header: headerText,
                  html: quotedHtml!,
                  onUnavailable: onHtmlUnavailable!,
                  onChanged: onHtmlChanged,
                )
              : controller != null
              ? DefaultTextStyle(
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: t.textSecondary,
                        height: 1.4,
                      ),
                  child: QuillEditor.basic(
                    key: const ValueKey('quoted_quill_editor'),
                    controller: controller!,
                    focusNode: focusNode ?? FocusNode(canRequestFocus: false),
                    config: QuillEditorConfig(
                      scrollable: false,
                      expands: false,
                      autoFocus: false,
                      showCursor: true,
                      padding: EdgeInsets.zero,
                      customStyleBuilder: customStyleBuilder,
                      embedBuilders: const [ComposeImageEmbedBuilder()],
                    ),
                  ),
                )
              : SelectableText(
                  '$headerText\n$fallbackText',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: t.textSecondary,
                        height: 1.4,
                      ),
                ),
        ),
      ],
    );
  }
}
