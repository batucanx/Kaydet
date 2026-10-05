import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/features/compose/recipient_chip_layout.dart';

/// Çiplerin satırlara dizilişi: sığmayan çip, satırda yeterli yer kalıyorsa
/// alt satıra atlamak yerine daraltılıp yan yana konur.
void main() {
  const available = 266.0;
  const spacing = 4.0;
  const min = 110.0;

  List<double> plan(List<double> natural) => RecipientChipLayout.maxWidths(
    naturalWidths: natural,
    available: available,
    spacing: spacing,
    minShrunkWidth: min,
  );

  test('hepsi sığıyorsa hiçbiri daraltılmaz', () {
    expect(plan([100, 80, 60]), [100, 80, 60]);
  });

  test('tam sınırda sığan çipler daraltılmaz', () {
    // 131 + 4 + 131 = 266
    expect(plan([131, 131]), [131, 131]);
  });

  test('sığmayan çip, kalan yer yeterliyse yan yana daraltılır', () {
    // Bayram DEDE + Kurumsal Mail Hizmeti: 140 + 4 + 231 > 266, kalan 122.
    expect(plan([140, 231]), [140, 122]);
  });

  test('kalan yer çok azsa çip alt satıra geçer, daraltılmaz', () {
    // Kalan 266 - 205 - 4 = 57 < 110.
    expect(plan([205, 231]), [205, 231]);
  });

  test(
    'daraltılan çipten sonra satır dolmuştur, sıradaki alt satıra geçer',
    () {
      // Üçüncü çip 100 dp isteğiyle yeni satırın başına gider, daraltılmaz.
      expect(plan([140, 231, 100]), [140, 122, 100]);
    },
  );

  test('alt satırda birikim yeniden başlar', () {
    // 200 | 200 (kalan 62 < 110, yeni satır) | 50 (200 + 4 + 50 sığar)
    expect(plan([200, 200, 50]), [200, 200, 50]);
  });

  test('tek başına satırdan geniş çip satır genişliğine indirilir', () {
    expect(plan([500]), [available]);
  });

  test('liste boşsa boş döner', () {
    expect(plan([]), isEmpty);
  });

  test('çıktı girdiyle aynı uzunluk ve sıradadır', () {
    final natural = [90.0, 300.0, 40.0, 250.0, 120.0];
    expect(plan(natural), hasLength(natural.length));
  });

  group('en fazla iki satır (RecipientChipPlanner)', () {
    // Bu grup yalnızca SATIR/yer mantığını sınar; görünen çip üst sınırı
    // (`maxVisible`, varsayılan 2) ayrı bir testte ele alınır.
    RecipientPlan twoLines(List<double> natural, {int maxVisible = 99}) =>
        RecipientChipPlanner.plan(
          naturalWidths: natural,
          available: available,
          spacing: spacing,
          minShrunkWidth: min,
          plusWidth: (_) => 30,
          inputMinWidth: 96,
          maxVisible: maxVisible,
        );

    test('az çip: hepsi görünür, gizlenen yok', () {
      final p = twoLines([100, 100]);
      expect(p.hidden, 0);
      expect(p.maxWidths, [100, 100]);
    });

    test('çok çip: satır sayısı ikiyi aşmaz, N gizlenenleri sayar', () {
      final natural = List.filled(10, 120.0);
      final p = twoLines(natural);
      expect(p.hidden, greaterThan(0));
      expect(p.maxWidths.length + p.hidden, natural.length);
    });

    test('varsayılan olarak en fazla iki çip görünür; yenisi en eskiyi gizler', () {
      final p = twoLines([60, 60, 60, 60], maxVisible: 2);
      expect(p.maxWidths.length, 2);
      expect(p.hidden, 2);
    });

    test('yazma alanı için yer kalmıyorsa çip gizlenir', () {
      // 3 çip x 120: ilk satırda 2, ikinci satırda 1 + yazma alanı sığar.
      expect(twoLines([120, 120, 120]).hidden, 0);
      // 4 çip x 120: ikinci satır iki çiple dolar, yazma alanı 3. satıra
      // düşerdi — bu yüzden en az bir çip gizlenir.
      expect(twoLines([120, 120, 120, 120]).hidden, greaterThan(0));
    });
  });
}
