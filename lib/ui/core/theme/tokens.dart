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
    required this.accentStrong,
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
  // Açık temada Outlook'un mavi üst çubuğuna yaklaşan `accent` tonu; koyu
  // temada zeminden (`bg`) ayrışıp drawer'la aynı gri tona (`surface`/
  // `surfaceDeep`) eşitlenir (bkz. `AppTheme._build` içindeki
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
  // İkinci, koyu vurgu tonu — açık temada Gelen Kutusu üst çubuğu gibi
  // `accentFill` zeminli yüzeylerin üzerinde ondan ayrışması gereken opak
  // pilli düğmeler (bkz. `_FilterMenuButton`) için. Koyu temada `accentFill`
  // ile aynıdır: koyu tema bu tondan etkilenmez.
  final Color accentStrong;

  final Color danger;
  final Color dangerFill;
  final Color success;
  final Color warning;

  final Color divider;
  final Color border;
  final Color scrim;

  final List<AvatarTone> avatarTones;

  bool get isDark => brightness == Brightness.dark;

  /// Yan menünün sol rayı — Magic Pattern `rail`: açık temada brand-950
  /// (#03241F), koyu temada #06070A. Üzerindeki ikon/metin her iki temada
  /// beyaz tabanlıdır (bkz. `FolderDrawer`).
  Color get rail => isDark ? const Color(0xFF06070A) : const Color(0xFF03241F);

  /// Üst çubuk (AppBar) zemini: tüm ekranlarda ve "Yeni ileti" düğmesinde
  /// ortak. Açık temada marka tonunun koyu hali (`accentStrong`, rail kadar
  /// koyu değil), koyu temada koyu yeşil (#062B24, siyah değil). Üzerindeki metin/ikon beyazdır.
  Color get topBar => isDark ? const Color(0xFF062B24) : accentStrong;

  /// "Sabitlenmiş" ikonu: açık temada belirgin siyah, koyu temada altın sarısı.
  Color get pinIcon => isDark ? warning : const Color(0xFF000000);

  /// Açık tema — Magic Pattern "tide-light" + "brand-jade" referansı.
  ///
  /// Zemin hiyerarşisi: üst çubuk `canvas` (#F7F8FA) üzerinde, liste/okuma
  /// yüzeyi beyaz `surface`; alanlar ve pilller `sunken` (#F0F2F5).
  static const KaydetTokens light = KaydetTokens(
    brightness: Brightness.light,
    bg: Color(0xFFFFFFFF),
    appBarBg: Color(0xFFF7F8FA),
    readingBg: Color(0xFFFFFFFF),
    surface: Color(0xFFF0F2F5),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceDeep: Color(0xFFF0F2F5),
    textPrimary: Color(0xFF14171C),
    textSecondary: Color(0xFF4B5361),
    textTertiary: Color(0xFF737D8C),
    accent: Color(0xFF0C8C76),
    accentFill: Color(0xFF0C8C76),
    onAccentFill: Color(0xFFFFFFFF),
    accentSubtle: Color(0xFFE7F8F4),
    // brand-600 (accent pressed): `accentFill` üstünde ayrışan koyu ton.
    accentStrong: Color(0xFF0A7564),
    danger: Color(0xFFE5484D),
    // Beyaz yazılı dolgularda kontrast için `danger`dan bir ton koyu.
    dangerFill: Color(0xFFC62A2F),
    success: Color(0xFF12A575),
    warning: Color(0xFFD98E04),
    divider: Color(0xFFE6E9EE),
    border: Color(0xFFE6E9EE),
    scrim: Color(0x73000000),
    avatarTones: _lightAvatarTones,
  );

  /// Koyu tema — Magic Pattern "tide-dark" referansı, varsayılan.
  ///
  /// Saf siyah yok; yüzeyler soğuk-nötr bir rampada basamak basamak açılır:
  ///   appBarBg (#0B0D11)               → canvas: üst çubuk
  ///   bg / surfaceDeep'in drawer'ı (#13161B) → liste ve drawer yüzeyi
  ///   readingBg / surface / surfaceElevated / surfaceDeep (#1A1E24)
  ///                                    → sunken: alan, pill, kart, diyalog,
  ///                                      alt sayfa ve mail okuma bölmesi
  ///                                      (near-black zeminde halation'ı
  ///                                      yumuşatmak için okuma da bunda).
  ///
  /// Vurgu ikiye ayrılır — koyu zeminde tek renk hem dolgu hem metin olamaz:
  ///   accent (#55C7AE, brand-300) → metin, ikon, gösterge
  ///   accentFill (#0C8C76)        → dolgu; üstünde beyaz metin
  static const KaydetTokens dark = KaydetTokens(
    brightness: Brightness.dark,
    bg: Color(0xFF13161B),
    appBarBg: Color(0xFF0B0D11),
    readingBg: Color(0xFF1A1E24),
    surface: Color(0xFF1A1E24),
    surfaceElevated: Color(0xFF1A1E24),
    surfaceDeep: Color(0xFF1A1E24),
    textPrimary: Color(0xFFF2F4F7),
    textSecondary: Color(0xFFB6BECA),
    textTertiary: Color(0xFF7E8896),
    accent: Color(0xFF55C7AE),
    accentFill: Color(0xFF0C8C76),
    onAccentFill: Color(0xFFFFFFFF),
    // Seçili klasör/liste satırı zemini (brand-950).
    accentSubtle: Color(0xFF03241F),
    accentStrong: Color(0xFF0C8C76),
    danger: Color(0xFFFF6369),
    dangerFill: Color(0xFFC5221F),
    success: Color(0xFF3DD68C),
    warning: Color(0xFFFFB224),
    divider: Color(0xFF242932),
    // Alan çerçevesi, onay kutusu, sheet tutamacı: sunken (#1A1E24) üstünde
    // görünsün diye ayraçtan (#242932) bir basamak belirgin.
    border: Color(0xFF2F3641),
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
    Color? accentStrong,
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
    accentStrong: accentStrong ?? this.accentStrong,
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
      accentStrong: c(accentStrong, other.accentStrong),
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
