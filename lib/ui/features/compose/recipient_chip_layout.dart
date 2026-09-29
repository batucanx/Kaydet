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

/// [RecipientChipLayout.plan]'ın sonucu: görünen çiplerin genişlik sınırları
/// ve gizlenen çip sayısı (`+N`'deki N).
class RecipientPlan {
  const RecipientPlan({required this.maxWidths, required this.hidden});

  /// Yalnızca GÖRÜNEN çipler için: listenin SONUNDAKİ `maxWidths.length` çip.
  final List<double> maxWidths;

  /// Gizlenen çip sayısı: toplam çip sayısı eksi görünenler.
  final int hidden;
}

abstract final class RecipientChipPlanner {
  /// Alıcı alanını en fazla [maxLines] satırla sınırlar. Çipler, sonda "+N"
  /// göstergesi (gizlenen varsa) ve yazma alanı için yer bırakılarak baştan
  /// olabildiğince çok çip gösterilecek biçimde dizilir; sığmayanlar gizlenir.
  ///
  /// Yerleşim `Wrap`in açgözlü kuralını taklit eder (bkz. [maxWidths]):
  /// [plusWidth], N gizli çip için "+N"in genişliği; [inputMinWidth], yazma
  /// alanının en az istediği genişliktir. "+N" ve yazma alanı da satıra sığmak
  /// zorundadır — ayrı bir üçüncü satır açılmaz, gerekirse daha çok çip gizlenir.
  static RecipientPlan plan({
    required List<double> naturalWidths,
    required double available,
    required double spacing,
    required double minShrunkWidth,
    required double Function(int hidden) plusWidth,
    required double inputMinWidth,
    int maxLines = 2,
  }) {
    final total = naturalWidths.length;
    for (var visible = total; visible >= 0; visible--) {
      final hidden = total - visible;
      final widths = <double>[];
      var lines = 1;
      var lineIsEmpty = true;
      var used = 0.0;

      // Boş olmayan satırda `width` sığıyorsa true; sığmıyorsa yeni satır açar.
      void place(double width) {
        final needed = lineIsEmpty ? width : used + spacing + width;
        if (needed <= available) {
          used = needed;
        } else {
          lines++;
          used = width;
        }
        lineIsEmpty = false;
      }

      // "+N" en başta, ardından SON eklenen çipler: en yeni alıcı hep görünür,
      // eskiler gizlenir.
      if (hidden > 0) place(math.min(plusWidth(hidden), available));
      for (var i = hidden; i < total; i++) {
        final width = math.min(naturalWidths[i], available);
        final needed = lineIsEmpty ? width : used + spacing + width;
        if (needed <= available) {
          widths.add(width);
          used = needed;
        } else {
          final room = (available - used - spacing).floorToDouble();
          if (room >= minShrunkWidth) {
            widths.add(room);
            used = available;
          } else {
            widths.add(width);
            lines++;
            used = width;
          }
        }
        lineIsEmpty = false;
      }

      place(math.min(inputMinWidth, available));

      if (lines <= maxLines) {
        return RecipientPlan(maxWidths: widths, hidden: hidden);
      }
    }
    return const RecipientPlan(maxWidths: [], hidden: 0);
  }
}
