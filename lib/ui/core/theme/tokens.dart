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
  // "Derinlik" push geçişinin süresi (bkz. `KaydetTransitionStyle.
  // horizontalPush`) — diğer geçişlerden (`page`/`pageBack`) bağımsız,
  // native/snappy hissettiren kendi hızında tutulur.
  static const Duration horizontalPush = Duration(milliseconds: 300);
  static const Duration horizontalPushBack = Duration(milliseconds: 250);

  // Yeni İleti / Compose ekranının açılış ve kapanış süreleri (bkz.
  // `KaydetTransitionStyle.compose`). iOS + Outlook tarzı, sakin ve
  // akıcı bir geçiş için 280 ms giriş, 220 ms dönüş.
  static const Duration compose = Duration(milliseconds: 280);
  static const Duration composeBack = Duration(milliseconds: 220);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.fastOutSlowIn;
  static const Curve symmetric = Curves.easeInOut;
}

/// Yazma ekranının metin/vurgu rengi paleti.
///
/// Bunlar arayüz rengi değil, e-posta İÇERİĞİNE yazılan renklerdir: alıcının
/// istemcisinde bu uygulamanın teması yoktur, bu yüzden açık/koyu temaya göre
/// değişmezler. Yine de kural gereği ham renk yalnızca bu dosyada durur.
abstract final class ComposePalette {
  /// Metin rengi seçenekleri (`#RRGGBB`).
  static const List<String> text = [
    '#EF4444', // kırmızı
    '#F97316', // turuncu
    '#F5C518', // altın
    '#22C55E', // yeşil
    '#14B8A6', // turkuaz
    '#3B82F6', // mavi
    '#8B5CF6', // mor
    '#EC4899', // pembe
    '#9CA3AF', // gri
  ];

  /// Vurgu (arka plan) rengi seçenekleri (`#RRGGBB`).
  static const List<String> highlight = [
    '#FEF08A', // sarı
    '#FED7AA', // turuncu
    '#BBF7D0', // yeşil
    '#BFDBFE', // mavi
    '#E9D5FF', // mor
    '#FBCFE8', // pembe
  ];

  static const Color _checkOnLight = Color(0xDD000000);
  static const Color _checkOnDark = Color(0xFFFFFFFF);

  /// `#RRGGBB` → [Color]. Geçersiz metin için `null`.
  static Color? tryParse(String hex) {
    final body = hex.startsWith('#') ? hex.substring(1) : hex;
    if (body.length != 6) return null;
    final value = int.tryParse(body, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  /// Renk karesinin üzerindeki onay işaretinin rengi — karenin KENDİ
  /// parlaklığına göre seçilir (tema değil), çünkü kare her temada aynıdır.
  static Color onSwatch(Color swatch) =>
      swatch.computeLuminance() > 0.5 ? _checkOnLight : _checkOnDark;
}

/// Sabit ölçüler.
abstract final class Dimens {
  static const double appBarHeight = 56;
  static const double bottomNavHeight = 60;
  // Küçültülmüş liste tipografisiyle (bkz. AppText.listSender*/
  // listSubject*/listPreview) iki satırlık içerik + dikey boşluk bu tabana
  // sığar; taşarsa `minHeight` olduğu için satır kendiliğinden büyür.
  // Kullanıcı isteğiyle sıkılaştırıldı: tek ekranda daha fazla ileti görünsün.
  static const double listRowMinHeight = 56;
  // Liste satırlarında gelen maillerin yanındaki avatar kutusu ölçeği.
  // Sıkılaştırılmış tipografiyle orantılı durması için 32 dp olarak tutulur.
  static const double avatarSize = 32;
  // Outlook'un hesap şeridindeki avatar ölçeği — yan menünün sol rayında
  // (bkz. `FolderDrawer`) hesap değiştirmeyi tek bakışta belirginleştirir.
  static const double navRailAvatarSize = 52;
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
    required this.appBarBg,
    required this.readingBg,
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
  // Çoğu temada `bg` ile aynıdır; yalnızca koyu temada AppBar'ın zeminden
  // farklı bir tonda olduğu için ayrışır (bkz. `AppTheme._build` içindeki
  // `appBarTheme.backgroundColor`).
  final Color appBarBg;
  // Mail detay ekranının okuma bölmesi (WebView gövdesi + iskelet dolgusu).
  // Açık temada `bg` ile aynıdır; koyu temada, liste/drawer'ın siyah olan
  // `bg`/`surfaceDeep`'inden ayrışan kendi gri tonu vardır (bkz.
  // `mail_detail_screen.dart`, `mail_html_document.dart`).
  final Color readingBg;
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

  /// Açık tema.
  static const KaydetTokens light = KaydetTokens(
    brightness: Brightness.light,
    bg: Color(0xFFFFFFFF),
    appBarBg: Color(0xFFFFFFFF),
    readingBg: Color(0xFFFFFFFF),
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

  /// Koyu tema — varsayılan.
  ///
  /// Gmail'in Material 3 "tonal" koyu temasından esinlenen, hafif soğuk bir
  /// nötr palet: saf siyah/beyaz yok, yüzeyler tek bir nötr rampada basamak
  /// basamak açılır (yükseltilmiş = daha açık) ve derinliği gölge değil ton
  /// farkı verir.
  ///
  /// Yüzey hiyerarşisi:
  ///   bg / appBarBg (#131314)         → Zemin, liste, üst çubuk
  ///   readingBg (#2A2A2A)             → Yalnızca mail okuma bölmesi (aşağı bkz.)
  ///   surface / surfaceDeep (#1E1F20) → Drawer, alan ve kart zemini
  ///   surfaceElevated (#282A2C)       → Diyalog, alt sayfa, araç çubuğu
  ///
  /// Vurgu ikiye ayrılır — koyu zeminde tek renk hem dolgu hem metin olamaz:
  ///   accent (#A8C7FA)     → metin, ikon, gösterge; zeminde 10,8:1
  ///   accentFill (#0B57D0) → dolgu (düğme, seçili avatar); üstünde beyaz 6,4:1
  ///
  /// Ölçülen kontrastlar (WCAG, bg üzerinde): ana metin 14,5:1, ikincil 10,9:1,
  /// üçüncül 5,8:1 (yükseltilmiş yüzeyde 4,5:1), danger 7,8:1, success 9,5:1,
  /// warning 13,2:1. `dangerFill` üzerinde beyaz 5,8:1.
  static const KaydetTokens dark = KaydetTokens(
    brightness: Brightness.dark,
    bg: Color(0xFF131314),
    appBarBg: Color(0xFF131314),
    // Uzun metin okunan tek yüzey: uygulamanın near-black zemininde açık
    // renkli metin parlar (halation) ve uzun okumada yorar. Nötr, orta-koyu
    // bir gri bunu yumuşatır. WebView zemini, iskelet ve mail renk dönüşümü
    // (bkz. `MailHtmlDocument`, `mail_render.js`) bu token'a uyar. Üzerinde
    // ana metin 11,2:1, ikincil 8,4:1, üçüncül 4,5:1 — bundan açık bir gri
    // (#2E2E2E+) tarih/metadata metnini 4,5:1'in altına düşürür.
    readingBg: Color(0xFF2A2A2A),
    surface: Color(0xFF1E1F20),
    surfaceElevated: Color(0xFF282A2C),
    surfaceDeep: Color(0xFF1E1F20),
    textPrimary: Color(0xFFE3E3E3),
    textSecondary: Color(0xFFC4C7C5),
    textTertiary: Color(0xFF8E918F),
    accent: Color(0xFFA8C7FA),
    accentFill: Color(0xFF0B57D0),
    onAccentFill: Color(0xFFFFFFFF),
    // Seçili klasör/liste satırının arka planı — bkz. `FolderDrawer`
    // içindeki `_FolderTile` ve `listTileTheme.selectedColor`. Üzerinde
    // `accent` 7,2:1, ana metin 9,7:1.
    accentSubtle: Color(0xFF1A3556),
    danger: Color(0xFFF28B82),
    dangerFill: Color(0xFFC5221F),
    success: Color(0xFF81C995),
    warning: Color(0xFFFDD663),
    // Yükseltilmiş yüzeyde de (diyalog, alt sayfa, araç çubuğu üst çizgisi)
    // seçilebilsin diye zeminde 1,6:1 — daha koyusu (#2E3032) orada 1,1:1'e
    // düşüp kayboluyordu.
    divider: Color(0xFF37393B),
    // Alan çerçevesi, onay kutusu, sheet tutamacı: ayraçtan bir basamak belirgin.
    border: Color(0xFF444746),
    scrim: Color(0x8C000000),
    avatarTones: _darkAvatarTones,
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
    Color? appBarBg,
    Color? readingBg,
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
    appBarBg: appBarBg ?? this.appBarBg,
    readingBg: readingBg ?? this.readingBg,
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
      appBarBg: c(appBarBg, other.appBarBg),
      readingBg: c(readingBg, other.readingBg),
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
