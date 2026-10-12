import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/tokens.dart';

/// Quill düzenleyicisinde gömülü görsel bloklarını (BlockEmbed.imageType)
/// hem yerel dosya yolu (galeri/imza) hem de uzak URL (HTTPS) için
/// canlı olarak çizen EmbedBuilder.
class ComposeImageEmbedBuilder extends EmbedBuilder {
  const ComposeImageEmbedBuilder();

  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(
    BuildContext context,
    EmbedContext embedContext,
  ) {
    final t = context.tokens;
    final node = embedContext.node;
    final source = node.value.data as String? ?? '';
    if (source.isEmpty) {
      return const SizedBox.shrink();
    }

    final isRemote =
        source.startsWith('http://') || source.startsWith('https://');
    final isData = source.toLowerCase().startsWith('data:');

    // Genişlik özniteliği (varsayılan: 200)
    double width = 200.0;
    var hasWidth = false;
    final rawWidth = node.style.attributes['width']?.value;
    if (rawWidth is int) {
      width = rawWidth.toDouble();
      hasWidth = true;
    } else if (rawWidth is double) {
      width = rawWidth;
      hasWidth = true;
    } else if (rawWidth is String) {
      final parsed = double.tryParse(rawWidth);
      if (parsed != null && parsed > 0) {
        width = parsed;
        hasWidth = true;
      }
    }

    Widget imageWidget;
    if (isData) {
      // Yanıtla/İlet ile taşınan orijinal ileti görselleri (bkz. `QuotedHtml`).
      // Baytlar belgenin içindedir; dosya yoluna bağlı değildir.
      final bytes = _decodeDataUri(source);
      if (bytes == null) {
        imageWidget = _missing(context, width, 'Görsel okunamadı');
      } else {
        // Genişlik verilmemişse görsel kendi boyutunda, ekrandan taşmayacak
        // şekilde çizilir (küçük bir logo 200 px'e şişirilmez).
        final maxWidth = math.max(
          80.0,
          MediaQuery.sizeOf(context).width - Space.xl * 2,
        );
        imageWidget = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Image.memory(
            bytes,
            width: hasWidth ? math.min(width, maxWidth) : null,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                _missing(context, width, 'Görsel okunamadı'),
          ),
        );
      }
    } else if (isRemote) {
      imageWidget = CachedNetworkImage(
        imageUrl: source,
        width: width,
        fit: BoxFit.contain,
        placeholder: (context, url) => Container(
          width: width,
          height: width * 0.4,
          decoration: BoxDecoration(
            color: t.surfaceDeep,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: t.border),
          ),
          alignment: Alignment.center,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: t.accent,
            ),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          width: width,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          decoration: BoxDecoration(
            color: t.surfaceDeep,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.imageOff, size: 16, color: t.danger),
              const SizedBox(width: Space.xs),
              Flexible(
                child: Text(
                  'Görsel yüklenemedi',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      final file = File(source);
      if (!file.existsSync()) {
        imageWidget = Container(
          width: width,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          decoration: BoxDecoration(
            color: t.surfaceDeep,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.imageOff, size: 16, color: t.textTertiary),
              const SizedBox(width: Space.xs),
              Flexible(
                child: Text(
                  'Görsel bulunamadı',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                ),
              ),
            ],
          ),
        );
      } else {
        imageWidget = Image.file(
          file,
          width: width,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Container(
            width: width,
            padding: const EdgeInsets.all(Space.sm),
            decoration: BoxDecoration(
              color: t.surfaceDeep,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(
              'Görsel okunamadı',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.danger),
            ),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: imageWidget,
      ),
    );
  }

  Widget _missing(BuildContext context, double width, String message) {
    final t = context.tokens;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        color: t.surfaceDeep,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 16, color: t.textTertiary),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// Yeniden çizimde aynı bayt listesi verilsin diye (`Image.memory` kimliği
  /// bayt listesinin kimliğidir; her seferinde yenisi, titreme ve yeniden
  /// çözümleme demek) çözülmüş baytlar küçük bir LRU önbellekte tutulur.
  static final Map<String, Uint8List?> _dataCache = {};
  static const int _dataCacheLimit = 24;

  static Uint8List? _decodeDataUri(String source) {
    if (_dataCache.containsKey(source)) {
      final hit = _dataCache.remove(source);
      _dataCache[source] = hit;
      return hit;
    }
    Uint8List? bytes;
    final comma = source.indexOf(',');
    if (comma > 0 && source.substring(0, comma).toLowerCase().endsWith(';base64')) {
      try {
        bytes = base64.decode(
          base64.normalize(source.substring(comma + 1).replaceAll(RegExp(r'\s+'), '')),
        );
      } on FormatException {
        bytes = null;
      }
    }
    if (bytes != null && bytes.isEmpty) bytes = null;
    _dataCache[source] = bytes;
    if (_dataCache.length > _dataCacheLimit) {
      _dataCache.remove(_dataCache.keys.first);
    }
    return bytes;
  }
}
