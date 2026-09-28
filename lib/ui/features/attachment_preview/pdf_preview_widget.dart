import 'dart:async';

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

  /// Resimdeki `PhotoView` çift-dokunma davranışıyla aynı his için: her zaman
  /// aynı hedef ölçeğe yakınlaştırır, tekrar dokununca sığdırılmış görünüme
  /// (ölçek 1.0) döner. Bkz. `_ImagePreview` — orada bu döngüyü `PhotoView`
  /// kendi içinde yönetir, burada `PdfControllerPinch.goTo` ile elle taklit
  /// edilir (pdfx paketi çift-dokunma sunmuyor).
  static const double _doubleTapZoomScale = 2.5;

  TapDownDetails? _doubleTapDetails;
  Object? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _handleDoubleTap() {
    final details = _doubleTapDetails;
    if (details == null) return;

    final isZoomedIn = _controller.zoomRatio > 1.05;
    if (isZoomedIn) {
      widget.onZoomChanged?.call(false);
      unawaited(_controller.goTo(destination: Matrix4.identity()));
      return;
    }

    final position = details.localPosition;
    final zoomed = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (_doubleTapZoomScale - 1),
        -position.dy * (_doubleTapZoomScale - 1),
        0,
        1,
      )
      ..scaleByDouble(
        _doubleTapZoomScale,
        _doubleTapZoomScale,
        _doubleTapZoomScale,
        1,
      );
    widget.onZoomChanged?.call(true);
    unawaited(_controller.goTo(destination: zoomed));
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
        GestureDetector(
          onDoubleTapDown: _handleDoubleTapDown,
          onDoubleTap: _handleDoubleTap,
          child: PdfViewPinch(
            controller: _controller,
            minScale: 1.0,
            maxScale: 4.5,
            backgroundDecoration: BoxDecoration(color: t.surfaceDeep),
            onDocumentError: (error) => setState(() => _error = error),
            onInteractionStart: widget.onZoomChanged == null
                ? null
                : (_) => widget.onZoomChanged!(true),
            onInteractionEnd: widget.onZoomChanged == null
                ? null
                : (_) => widget.onZoomChanged!(false),
          ),
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
