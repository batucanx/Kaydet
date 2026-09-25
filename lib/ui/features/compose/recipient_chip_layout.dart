import 'dart:math' as math;

/// Alıcı çiplerinin satırlara nasıl dizileceğini önceden hesaplar.
///
/// `Wrap` sığmayan çipi bütünüyle bir alt satıra atar; iki uzun ad ("Bayram
/// DEDE", "Kurumsal Mail Hizmeti") yan yana sığmayınca her biri kendi satırında
/// kalır ve alan gereksiz uzar. Burada `Wrap`in açgözlü yerleşimi taklit edilir
/// ve bir çip satırda kalan boşluğa sığmıyor ama o boşluk kullanılabilir
/// genişlikteyse ([minShrunkWidth]), çip o boşluğa kadar daraltılır (adı
/// "…" ile kısalır) ve yan yana durur. Boşluk bundan azsa çip alt satıra geçer.
///
/// Sonuç `Wrap`e verilen çip başına üst sınırdır; `Wrap` gerçek yerleşimi
/// yine kendisi yapar, bu yüzden bir ölçüm sapması en kötü ihtimalle eski
/// davranışa (çipin alt satıra geçmesi) düşer, asla taşmaya yol açmaz.
abstract final class RecipientChipLayout {
  /// [naturalWidths]: her çipin kısaltılmadan istediği genişlik.
  /// [available]: çiplerin dizildiği satırın genişliği.
  /// [spacing]: çipler arası yatay boşluk.
  ///
  /// Dönen liste [naturalWidths] ile aynı uzunluk ve sıradadır; her değer
  /// ilgili çipin doğal genişliğini aşmaz.
  static List<double> maxWidths({
    required List<double> naturalWidths,
    required double available,
    required double spacing,
    required double minShrunkWidth,
  }) {
    final result = <double>[];
    var lineIsEmpty = true;
    // Bu satırda şimdiye kadar dolan genişlik (`lineIsEmpty` iken anlamsız).
    var used = 0.0;

    for (final natural in naturalWidths) {
      // Tek başına satırdan geniş çip satır genişliğine iner.
      final width = math.min(natural, available);

      // Boş satıra her çip sığar (`width <= available`).
      final needed = lineIsEmpty ? width : used + spacing + width;
      if (needed <= available) {
        result.add(width);
        used = needed;
        lineIsEmpty = false;
        continue;
      }

      // Buraya gelindiyse satır doludur ve çip sığmamıştır. Satırda kalan
      // boşluk kullanılabilirse çip ona daraltılır; `floor`, `Wrap`in sınır
      // karşılaştırmasında kayan nokta payına takılmamak için. Daraltılan çip
      // satırı doldurur, sıradaki yeni satıra geçer.
      final room = (available - used - spacing).floorToDouble();
      if (room >= minShrunkWidth) {
        result.add(room);
        used = available;
        continue;
      }

      // Yeni satır.
      result.add(width);
      used = width;
    }
    return result;
  }
}
