import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// PDF belgelerini yüksek performans, pinch-to-zoom (yakınlaştırma), pan ve
/// sayfa numaralandırmasıyla ekranda görüntüleyen paylaşımlı önizleme bileşeni.
///
/// Hem saf PDF ekleri hem de önizleme için PDF formatına dönüştürülen Office
/// belgeleri (DOCX vb.) bu bileşeni ortaklaşa kullanır.
class PdfPreviewWidget extends StatefulWidget {
  const PdfPreviewWidget({
    super.key,
    required this.path,
    this.errorMessage = 'PDF açılamadı',
    this.errorDescription = 'Dosya bozuk olabilir.',
    this.errorAction,
    this.onZoomChanged,
  });

  final String path;
  final String errorMessage;
  final String errorDescription;
  final Widget? errorAction;

  /// Kullanıcı sayfa içinde pinch/pan ile etkileşime başlayıp bitirdiğinde
  /// bildirir (`true`/`false`). Birden çok ek arasında geçişi sağlayan üst
  /// pager (bkz. `attachment_preview_screen.dart`), etkileşim sürerken kendi
  /// yatay kaydırmasını kilitler — aksi halde pinch/pan ile sayfa geçişi
  /// gesture'ı çakışır.
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<PdfPreviewWidget> createState() => _PdfPreviewWidgetState();
}

class _PdfPreviewWidgetState extends State<PdfPreviewWidget> {
  late final PdfControllerPinch _controller = PdfControllerPinch(
    document: PdfDocument.openFile(widget.path),
  );

  Object? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (_error != null) {
      return Center(
        child: EmptyState(
          icon: LucideIcons.fileWarning,
          title: widget.errorMessage,
          description: widget.errorDescription,
          action: widget.errorAction,
        ),
      );
    }
    return Stack(
      children: [
        PdfViewPinch(
          controller: _controller,
          backgroundDecoration: BoxDecoration(color: t.surfaceDeep),
          onDocumentError: (error) => setState(() => _error = error),
          onInteractionStart: widget.onZoomChanged == null
              ? null
              : (_) => widget.onZoomChanged!(true),
          onInteractionEnd: widget.onZoomChanged == null
              ? null
              : (_) => widget.onZoomChanged!(false),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: Space.lg,
          child: Center(
            child: ValueListenableBuilder<int>(
              valueListenable: _controller.pageListenable,
              builder: (context, page, _) {
                final total = _controller.pagesCount;
                if (total == null) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: Space.xs,
                  ),
                  decoration: BoxDecoration(
                    color: t.surfaceElevated,
                    borderRadius: BorderRadius.circular(Radii.full),
                  ),
                  child: Text(
                    '$page / $total',
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: t.textSecondary),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
