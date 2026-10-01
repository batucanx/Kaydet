import 'dart:io';

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

    // Genişlik özniteliği (varsayılan: 200)
    double width = 200.0;
    final rawWidth = node.style.attributes['width']?.value;
    if (rawWidth is int) {
      width = rawWidth.toDouble();
    } else if (rawWidth is double) {
      width = rawWidth;
    } else if (rawWidth is String) {
      final parsed = double.tryParse(rawWidth);
      if (parsed != null && parsed > 0) {
        width = parsed;
      }
    }

    Widget imageWidget;
    if (isRemote) {
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
}
