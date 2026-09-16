import 'package:flutter/material.dart';

/// Tasarım sistemi token'ları — `docs/plan/04-tasarim-sistemi.md` ile birebir.
///
/// KURAL: Widget'larda ham renk kullanılmaz. Her renk buradan gelir.
/// Erişim: `context.tokens.accent`
///
/// Koyu temadaki tüm metin/zemin çiftleri WCAG kontrast hesabından geçirilmiştir;
/// değerlerin yanındaki oranlar ölçülmüş sonuçlardır.

/// Bir avatar tonu: zemin + harf rengi.
@immutable
class AvatarTone {
  const AvatarTone(this.background, this.foreground);
  final Color background;
  final Color foreground;

  static AvatarTone lerp(AvatarTone a, AvatarTone b, double t) => AvatarTone(
    Color.lerp(a.background, b.background, t) ?? a.background,
    Color.lerp(a.foreground, b.foreground, t) ?? a.foreground,
  );
}

/// Boşluk ölçeği (4 dp tabanlı). Tema değişiminden etkilenmez.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;
  static const double giant = 48;
}

/// Köşe yarıçapı ölçeği.
abstract final class Radii {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double full = 999;
}

/// İkon boyutu ölçeği.
abstract final class IconSize {
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 32;
}

/// Hareket süreleri.
abstract final class Motion {
  static const Duration instant = Duration.zero;
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Duration page = Duration(milliseconds: 320);
  static const Duration pageBack = Duration(milliseconds: 240);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.fastOutSlowIn;
  static const Curve symmetric = Curves.easeInOut;
}

/// Sabit ölçüler.
abstract final class Dimens {
  static const double appBarHeight = 56;
  static const double bottomNavHeight = 60;
  // Outlook ölçeğindeki liste tipografisiyle (bkz. AppText.listSender*/
  // listSubject*/listPreview) iki satırlık içerik + dikey boşluk bu tabana
  // sığar; taşarsa `minHeight` olduğu için satır kendiliğinden büyür.
  static const double listRowMinHeight = 64;
  static const double avatarSize = 36;
  static const double fabSize = 56;
  static const double touchTarget = 48;
  static const double controlHeight = 48;
  static const double dividerThickness = 1;
}

@immutable
class KaydetTokens extends ThemeExtension<KaydetTokens> {
  const KaydetTokens({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceDeep,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentFill,
    required this.onAccentFill,
    required this.accentSubtle,
    required this.danger,
    required this.dangerFill,
    required this.success,
    required this.warning,
    required this.divider,
    required this.border,
    required this.scrim,
    required this.avatarTones,
  });

  final Brightness brightness;

  final Color bg;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceDeep;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color accent;
  final Color accentFill;
  final Color onAccentFill;
  final Color accentSubtle;

  final Color danger;
  final Color dangerFill;
  final Color success;
  final Color warning;

  final Color divider;
  final Color border;
  final Color scrim;

  final List<AvatarTone> avatarTones;

  bool get isDark => brightness == Brightness.dark;

  /// Koyu tema — varsayılan. eM Client'ın koyu paletiyle eşleşecek şekilde
  /// nötr, mavimsi bir kömür tonu kullanır (önceki sürüm daha yeşil/turkuaz
  /// kaçıyordu).
  static const KaydetTokens dark = KaydetTokens(
    brightness: Brightness.dark,
    bg: Color(0xFF0E1114),
    surface: Color(0xFF13161A),
    surfaceElevated: Color(0xFF1A1E24),
    surfaceDeep: Color(0xFF090B0D),
    textPrimary: Color(0xFFE8EEF1), // 16.17:1
    textSecondary: Color(0xFF9FB0B8), // 8.46:1
    textTertiary: Color(0xFF6B7D85), // 4.42:1
    accent: Color(0xFF4A9EE0), // 6.55:1 (metin/ikon)
    accentFill: Color(0xFF2478C7), // beyaz metinle 4.58:1
    onAccentFill: Color(0xFFFFFFFF),
    accentSubtle: Color(0x1F4A9EE0),
    danger: Color(0xFFEC5A5F), // 5.59:1
    dangerFill: Color(0xFFC62A2F), // beyaz metinle 5.57:1
    success: Color(0xFF30A46C), // 6.00:1
    warning: Color(0xFFF5A623), // 9.34:1
    divider: Color(0xFF20242A),
    border: Color(0xFF2C323A),
    scrim: Color(0x8C000000),
    avatarTones: _darkAvatarTones,
  );

  /// Açık tema.
  static const KaydetTokens light = KaydetTokens(
    brightness: Brightness.light,
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF6F8F9),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceDeep: Color(0xFFEEF2F4),
    textPrimary: Color(0xFF0F1619), // 18.27:1
    textSecondary: Color(0xFF5A6B73), // 5.55:1
    textTertiary: Color(0xFF7C8B93), // 3.52:1
    accent: Color(0xFF1B72C4), // 4.94:1
    accentFill: Color(0xFF1B72C4),
    onAccentFill: Color(0xFFFFFFFF),
    accentSubtle: Color(0x141B72C4),
    danger: Color(0xFFC62A2F), // 5.57:1
    dangerFill: Color(0xFFC62A2F),
    success: Color(0xFF1A7F4B),
    warning: Color(0xFFB26A00),
    divider: Color(0xFFE3E8EA),
    border: Color(0xFFD3DBDE),
    scrim: Color(0x73000000),
    avatarTones: _lightAvatarTones,
  );

  /// 15 ton — hepsinde harf/zemin kontrastı ≥ 6:1 (ölçüldü).
  static const List<AvatarTone> _darkAvatarTones = [
    AvatarTone(Color(0xFF56312E), Color(0xFFE8B4B0)),
    AvatarTone(Color(0xFF563A2E), Color(0xFFE8C1B0)),
    AvatarTone(Color(0xFF56442E), Color(0xFFE8CEB0)),
    AvatarTone(Color(0xFF564C2E), Color(0xFFE8DAB0)),
    AvatarTone(Color(0xFF55562E), Color(0xFFE6E8B0)),
    AvatarTone(Color(0xFF44562E), Color(0xFFCEE8B0)),
    AvatarTone(Color(0xFF2E563C), Color(0xFFB0E8C3)),
    AvatarTone(Color(0xFF2E564E), Color(0xFFB0E8DD)),
    AvatarTone(Color(0xFF2E5156), Color(0xFFB0E1E8)),
    AvatarTone(Color(0xFF2E4656), Color(0xFFB0D1E8)),
    AvatarTone(Color(0xFF2E3456), Color(0xFFB0B7E8)),
    AvatarTone(Color(0xFF3A2E56), Color(0xFFC1B0E8)),
    AvatarTone(Color(0xFF4C2E56), Color(0xFFDAB0E8)),
    AvatarTone(Color(0xFF562E4E), Color(0xFFE8B0DD)),
    AvatarTone(Color(0xFF562E3D), Color(0xFFE8B0C5)),
  ];

  static const List<AvatarTone> _lightAvatarTones = [
    AvatarTone(Color(0xFFF0DCDB), Color(0xFF6F2520)),
    AvatarTone(Color(0xFFF0E1DB), Color(0xFF6F3820)),
    AvatarTone(Color(0xFFF0E6DB), Color(0xFF6F4A20)),
    AvatarTone(Color(0xFFF0EBDB), Color(0xFF6F5B20)),
    AvatarTone(Color(0xFFEFF0DB), Color(0xFF6C6F20)),
    AvatarTone(Color(0xFFE6F0DB), Color(0xFF4A6F20)),
    AvatarTone(Color(0xFFDBF0E2), Color(0xFF206F3A)),
    AvatarTone(Color(0xFFDBF0EC), Color(0xFF206F5F)),
    AvatarTone(Color(0xFFDBEDF0), Color(0xFF20646F)),
    AvatarTone(Color(0xFFDBE7F0), Color(0xFF204E6F)),
    AvatarTone(Color(0xFFDBDEF0), Color(0xFF202B6F)),
    AvatarTone(Color(0xFFE1DBF0), Color(0xFF38206F)),
    AvatarTone(Color(0xFFEBDBF0), Color(0xFF5B206F)),
    AvatarTone(Color(0xFFF0DBEC), Color(0xFF6F205F)),
    AvatarTone(Color(0xFFF0DBE3), Color(0xFF6F203D)),
  ];

  /// Etiket renkleri — kullanıcı etiket oluştururken seçer.
  static const List<String> labelToneNames = [
    'Kırmızı',
    'Turuncu',
    'Kehribar',
    'Altın',
    'Zeytin',
    'Yeşil',
    'Çimen',
    'Zümrüt',
    'Turkuaz',
    'Gök',
    'Mavi',
    'İndigo',
    'Mor',
    'Orkide',
    'Gül',
  ];

  AvatarTone toneAt(int index) => avatarTones[index.abs() % avatarTones.length];

  @override
  KaydetTokens copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceDeep,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentFill,
    Color? onAccentFill,
    Color? accentSubtle,
    Color? danger,
    Color? dangerFill,
    Color? success,
    Color? warning,
    Color? divider,
    Color? border,
    Color? scrim,
    List<AvatarTone>? avatarTones,
  }) => KaydetTokens(
    brightness: brightness ?? this.brightness,
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    surfaceDeep: surfaceDeep ?? this.surfaceDeep,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    accent: accent ?? this.accent,
    accentFill: accentFill ?? this.accentFill,
    onAccentFill: onAccentFill ?? this.onAccentFill,
    accentSubtle: accentSubtle ?? this.accentSubtle,
    danger: danger ?? this.danger,
    dangerFill: dangerFill ?? this.dangerFill,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    divider: divider ?? this.divider,
    border: border ?? this.border,
    scrim: scrim ?? this.scrim,
    avatarTones: avatarTones ?? this.avatarTones,
  );

  @override
  KaydetTokens lerp(ThemeExtension<KaydetTokens>? other, double t) {
    if (other is! KaydetTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return KaydetTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      surfaceElevated: c(surfaceElevated, other.surfaceElevated),
      surfaceDeep: c(surfaceDeep, other.surfaceDeep),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
      accent: c(accent, other.accent),
      accentFill: c(accentFill, other.accentFill),
      onAccentFill: c(onAccentFill, other.onAccentFill),
      accentSubtle: c(accentSubtle, other.accentSubtle),
      danger: c(danger, other.danger),
      dangerFill: c(dangerFill, other.dangerFill),
      success: c(success, other.success),
      warning: c(warning, other.warning),
      divider: c(divider, other.divider),
      border: c(border, other.border),
      scrim: c(scrim, other.scrim),
      avatarTones: t < 0.5 ? avatarTones : other.avatarTones,
    );
  }
}

/// `context.tokens` kısayolu.
extension KaydetThemeContext on BuildContext {
  KaydetTokens get tokens =>
      Theme.of(this).extension<KaydetTokens>() ?? KaydetTokens.dark;

  /// Erişilebilirlik: animasyon kapalıysa süre sıfırlanır.
  Duration motion(Duration duration) =>
      MediaQuery.maybeDisableAnimationsOf(this) ?? false
      ? Duration.zero
      : duration;
}
