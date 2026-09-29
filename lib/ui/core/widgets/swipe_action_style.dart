import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/services/app_settings.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/swipe_action_resolver.dart';
import '../theme/tokens.dart';

/// Bir kaydırma eyleminin görünümü: zemin, ön plan, simge ve etiket.
/// Mail listesindeki gerçek kaydırma alanı ve Çekme seçenekleri önizlemesi
/// AYNI stili kullanır; böylece önizleme gerçek davranışı yansıtır.
class SwipeStyle {
  const SwipeStyle({
    required this.color,
    required this.foreground,
    required this.icon,
    required this.label,
  });

  final Color color;
  final Color foreground;
  final IconData icon;
  final String label;

  /// [EffectiveSwipe.none] için `null`: gösterilecek bir alan yoktur.
  static SwipeStyle? of(EffectiveSwipe action, KaydetTokens t) {
    // Sabitle sarı/amber zemin kullanır; koyu temada bu açık bir tondur ve
    // beyaz simge okunmaz — o zaman koyu mürekkep rengi kullanılır (bkz.
    // `KaydetNotice`teki aynı desen).
    final onWarning = t.isDark ? KaydetTokens.light.textPrimary : t.onAccentFill;
    return switch (action) {
      EffectiveSwipe.none => null,
      EffectiveSwipe.archive => SwipeStyle(
        color: t.success,
        foreground: t.onAccentFill,
        icon: LucideIcons.archive,
        label: 'Arşivle',
      ),
      EffectiveSwipe.moveToInbox => SwipeStyle(
        // `accent` koyu temada METİN için ayarlı açık bir tondur; dolgu
        // olarak `accentFill` (bkz. `tokens.dart`).
        color: t.accentFill,
        foreground: t.onAccentFill,
        icon: LucideIcons.inbox,
        label: 'Gelen Kutusuna Taşı',
      ),
      EffectiveSwipe.delete => SwipeStyle(
        color: t.dangerFill,
        foreground: t.onAccentFill,
        icon: LucideIcons.trash2,
        label: 'Sil',
      ),
      EffectiveSwipe.markRead => SwipeStyle(
        color: t.accentFill,
        foreground: t.onAccentFill,
        icon: LucideIcons.mailOpen,
        label: 'Okundu',
      ),
      EffectiveSwipe.markUnread => SwipeStyle(
        color: t.accentFill,
        foreground: t.onAccentFill,
        icon: LucideIcons.mail,
        label: 'Okunmadı',
      ),
      EffectiveSwipe.pin => SwipeStyle(
        color: t.warning,
        foreground: onWarning,
        icon: LucideIcons.pin,
        label: 'Sabitle',
      ),
      EffectiveSwipe.configure => SwipeStyle(
        // Tema zeminiyle uyumlu, nötr bir alan (koyu/açık temada token'dan).
        color: t.isDark ? t.surfaceElevated : t.surfaceDeep,
        foreground: t.textPrimary,
        icon: LucideIcons.slidersHorizontal,
        label: 'Eylemleri ayarlamak için çekin',
      ),
      EffectiveSwipe.unpin => SwipeStyle(
        color: t.warning,
        foreground: onWarning,
        icon: LucideIcons.pinOff,
        label: 'Sabitlemeyi Kaldır',
      ),
    };
  }

  /// Ayarlardaki bir seçimin Gelen Kutusu'ndaki (okunmamış, sabitsiz bir
  /// iletideki) görünümü — Çekme seçenekleri ekranı ve seçim listesi için.
  static SwipeStyle? forSelection(SwipeAction action, KaydetTokens t) {
    final effective = SwipeActionResolver.resolve(
      selected: action,
      folder: SpecialUse.inbox,
      isDraftOrLocal: false,
      isSeen: false,
      isFlagged: false,
    );
    if (action == SwipeAction.configure) {
      return SwipeStyle(
        color: t.isDark ? t.surfaceElevated : t.surfaceDeep,
        foreground: t.textPrimary,
        icon: LucideIcons.slidersHorizontal,
        label: 'Ayarla',
      );
    }
    if (action == SwipeAction.readAndArchive) {
      return SwipeStyle(
        color: t.success,
        foreground: t.onAccentFill,
        icon: LucideIcons.mailCheck,
        label: 'Oku ve arşivle',
      );
    }
    if (action == SwipeAction.toggleRead) {
      return SwipeStyle(
        color: t.accentFill,
        foreground: t.onAccentFill,
        icon: LucideIcons.mailOpen,
        label: 'Okundu / okunmadı',
      );
    }
    return of(effective, t);
  }
}
