/// Yazma ekranındaki biçimlendirme seçeneklerinin KONTROLLÜ modeli.
///
/// Editöre ve giden HTML'e yalnızca buradaki değerler girer. Serbest bir
/// `font-size` metni (ör. `'18px'`) editöre yazılırsa `flutter_quill` onu
/// `double.tryParse` ile okur, `null` alır ve `TextLine` çizimi sırasında
/// `ArgumentError` fırlatır; hata `RenderEditor`'a kadar tırmanıp editörün
/// tamamını boş bir `ErrorWidget`'a çevirir. Bu yüzden dışarıdan gelen her
/// değer (araç çubuğu, taslak HTML'i, yapıştırma) önce bu modelden geçer:
/// tanınmayan değer atılır, tanınan değer en yakın seviyeye oturtulur.
library;

/// Yazı boyutu seviyeleri — px cinsinden değerler hem editörde hem de giden
/// HTML'de aynıdır (Flutter mantıksal pikseli = CSS pikseli).
///
/// [normal] editörün taban boyutudur (bkz. `DefaultStyles` — 16) ve Quill'de
/// hiçbir öznitelik taşımaz; giden HTML'de her satırın taban boyutu olarak
/// yazılır. Diğer seviyeler yalnızca seçili metne uygulanır.
enum ComposeFontSize {
  small(13),
  normal(16),
  large(20),
  extraLarge(24);

  const ComposeFontSize(this.px);

  final int px;

  /// Quill `size` özniteliğinin değeri. Yalnızca düz sayı metnidir (`'20'`):
  /// `flutter_quill` bunu güvenle okur ve `HtmlToDelta` da aynı biçimi
  /// üretir. [normal] için `null` — öznitelik hiç yazılmaz/kaldırılır.
  String? get attributeValue => this == normal ? null : '$px';

  /// [pixels]'e en yakın seviye. Sınırlar seviyelerin orta noktalarıdır;
  /// böylece 14px küçük, 15px normal, 18px büyük, 22px çok büyük sayılır. Aralık dışı
  /// değerler uçtaki seviyeye kelepçelenir — hiçbir girdi 24px'i aşan bir
  /// çizim üretemez. NaN → [normal].
  static ComposeFontSize fromPx(double pixels) {
    if (pixels.isNaN) return normal;
    if (pixels.isInfinite) return pixels > 0 ? extraLarge : small;
    ComposeFontSize best = normal;
    var bestDistance = double.infinity;
    for (final level in values) {
      final distance = (level.px - pixels).abs();
      // `<=`: tam orta noktada (18px, 22px) büyük seviye kazanır. Quill'in
      // kendi `large`/`huge` adları da 18/22px'tir ve bu seviyelere karşılık
      // gelir.
      if (distance <= bestDistance) {
        best = level;
        bestDistance = distance;
      }
    }
    return best;
  }

  static final RegExp _length = RegExp(
    r'^\s*([0-9]*\.?[0-9]+)\s*(px|pt|em|rem|%)?\s*$',
    caseSensitive: false,
  );

  /// Quill `size` özniteliğinin ya da bir CSS `font-size` değerinin (`'18'`,
  /// `'18px'`, `'14pt'`, `'1.5em'`, `'large'`, `18.0`) karşılığı.
  ///
  /// `null` girdisi "öznitelik yok" demektir → [normal]. Anlaşılamayan bir
  /// değer için `null` döner; çağıran tarafın o özniteliği ATMASI gerekir.
  /// [parentPx] `em`/`%` gibi göreli birimlerin dayanağıdır.
  static ComposeFontSize? fromAttribute(Object? value, {double parentPx = 16}) {
    if (value == null) return normal;
    if (value is num) return value.isFinite ? fromPx(value.toDouble()) : null;
    if (value is! String) return null;

    switch (value.trim().toLowerCase()) {
      case 'small' || 'x-small' || 'xx-small':
        return small;
      case 'normal' || 'medium':
        return normal;
      case 'large' || 'x-large':
        return large;
      case 'huge' || 'xx-large' || 'xxx-large':
        return extraLarge;
    }

    final px = cssLengthToPx(value, parentPx: parentPx);
    return px == null ? null : fromPx(px);
  }

  /// `'18px'`, `'14pt'`, `'1.5em'`, `'120%'` gibi bir CSS uzunluğunu piksele
  /// çevirir; anlaşılamazsa `null`.
  static double? cssLengthToPx(String value, {double parentPx = 16}) {
    final match = _length.firstMatch(value);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null || !number.isFinite) return null;
    return switch (match.group(2)?.toLowerCase()) {
      null || 'px' => number,
      'pt' => number * 4 / 3,
      'em' => number * parentPx,
      'rem' => number * 16,
      '%' => number * parentPx / 100,
      _ => null,
    };
  }
}

/// Satır aralığı seçenekleri. Değerler birimsiz çarpandır (CSS `line-height`
/// ile Flutter `TextStyle.height` aynı anlama gelir) ve editörde de giden
/// HTML'de de BİREBİR aynı uygulanır.
///
/// [normal] editörün taban aralığıdır ve öznitelik taşımaz.
enum ComposeLineSpacing {
  tight(1),
  normal(baseHeight),
  oneAndHalf(1.5),
  doubled(2);

  const ComposeLineSpacing(this.height);

  /// Editörün ve giden HTML'in taban satır aralığı (Quill'in varsayılanı,
  /// Gmail/Outlook'un varsayılanına yakın).
  static const double baseHeight = 1.15;

  final double height;

  /// Quill `line-height` özniteliğinin değeri; [normal] için `null`.
  double? get attributeValue => this == normal ? null : height;

  /// Girdi tanınmazsa `null` (öznitelik atılır). `null` "öznitelik yok" →
  /// [normal]. Sayılar en yakın seçeneğe oturtulur.
  static ComposeLineSpacing? fromAttribute(Object? value) {
    if (value == null) return normal;
    if (value is! num || !value.isFinite) return null;
    ComposeLineSpacing best = normal;
    var bestDistance = double.infinity;
    for (final option in values) {
      final distance = (option.height - value.toDouble()).abs();
      if (distance < bestDistance) {
        best = option;
        bestDistance = distance;
      }
    }
    return best;
  }
}
