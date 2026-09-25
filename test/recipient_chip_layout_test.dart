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
}
