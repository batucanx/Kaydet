import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/core/widgets/attachment_summary.dart';

AttachmentEntry entry(
  String name, {
  int size = 2048,
  bool pending = false,
  void Function(BuildContext)? onOpen,
  VoidCallback? onRemove,
}) => AttachmentEntry(
  name: name,
  mimeType: 'image/png',
  sizeBytes: size,
  pending: pending,
  onOpen: onOpen,
  onRemove: onRemove,
);

void main() {
  // Ahem: her karakter tam fontSize genişliğinde — ölçüler deterministik.
  const style = TextStyle(fontFamily: 'Ahem', fontSize: 10);

  group('middleEllipsize', () {
    test('sığıyorsa aynen döner', () {
      expect(middleEllipsize('rapor.pdf', 1000, style), 'rapor.pdf');
      expect(middleEllipsize('rapor.pdf', 90, style), 'rapor.pdf');
    });

    test('uzantıyı korur, ortadan keser', () {
      const name = '1aecf3ec1401151ab3b6385980abcdef0123456789.png';
      // 200px = 20 karakter: baş (12) + … + son 7 ('789.png').
      expect(middleEllipsize(name, 200, style), '1aecf3ec1401…789.png');
    });

    test('uzantısız karma adda sonu da gösterir', () {
      const name = '1aecf3ec1401151ab3b6385980abcdef0123456789';
      // 150px = 15 karakter: baş (11) + … + son 3.
      expect(middleEllipsize(name, 150, style), '1aecf3ec140…789');
    });

    test('sonuç her genişlikte sığar (en dar sınırın üstünde)', () {
      const name = 'çok-uzun-bir-dosya-adı-ve-ek-bilgiler-içeren-belge.docx';
      for (var width = 100.0; width <= 500; width += 17) {
        final out = middleEllipsize(name, width, style);
        final painter = TextPainter(
          text: TextSpan(text: out, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(
          painter.width,
          lessThanOrEqualTo(width),
          reason: 'w=$width $out',
        );
        expect(out, endsWith('.docx'));
      }
    });

    test('boş ve sonsuz genişlikte dokunmaz', () {
      expect(middleEllipsize('', 100, style), '');
      expect(middleEllipsize('abc', double.infinity, style), 'abc');
    });
  });

  group('AttachmentSummary', () {
    Future<void> pump(
      WidgetTester tester,
      List<AttachmentEntry> entries, {
      double width = 360,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: AttachmentSummary(entries: entries),
            ),
          ),
        ),
      );
    }

    List<AttachmentEntry> many(int n, {void Function(BuildContext)? onOpen}) =>
        [
          for (var i = 1; i <= n; i++)
            entry('ek$i-1aecf3ec1401151ab3b6385980abcdef.png', onOpen: onOpen),
        ];

    testWidgets('4 ve altı: tümü çip, "+N" yok', (tester) async {
      await pump(tester, many(4));
      expect(find.byType(Tooltip), findsNWidgets(4));
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('10 ek: yalnızca ilk 4 çip + "+6 ek"; yükseklik sınırlı', (
      tester,
    ) async {
      await pump(tester, many(10));
      expect(find.byType(Tooltip), findsNWidgets(4));
      expect(find.text('+6 ek'), findsOneWidget);
      // Telefon genişliğinde en çok 3 satır: eskiden 10 büyük kart alt alta idi.
      expect(
        tester.getSize(find.byType(AttachmentSummary)).height,
        lessThan(130),
      );
    });

    testWidgets('uzun adlar taşmaz', (tester) async {
      await pump(tester, many(10));
      expect(tester.takeException(), isNull);
    });

    testWidgets('"+N ek" tüm ekleri listeler; satıra dokununca önizleme '
        'açılır', (tester) async {
      var opened = <String>[];
      await pump(tester, [
        for (var i = 1; i <= 6; i++)
          entry('foto$i.png', onOpen: (_) => opened.add('foto$i.png')),
      ]);
      await tester.tap(find.text('+2 ek'));
      await tester.pumpAndSettle();

      expect(find.text('Ekler'), findsOneWidget);
      expect(find.text('6 ek · 12 KB'), findsOneWidget);
      // Sayfadaki satırlar: 6; (arka plandaki 4 çip de ağaçta, ama ad aynı)
      expect(find.text('foto6.png'), findsOneWidget);

      await tester.ensureVisible(find.text('foto6.png'));
      await tester.tap(find.text('foto6.png'));
      await tester.pump();
      expect(opened, ['foto6.png']);
    });

    testWidgets('liste sayfasından kaldırınca canlı güncellenir; hepsi '
        'kalkınca sayfa kapanır', (tester) async {
      final names = ['a.png', 'b.png', 'c.png', 'd.png', 'e.png', 'f.png'];
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return AttachmentSummary(
                  entries: [
                    for (final n in names)
                      entry(n, onRemove: () => setOuter(() => names.remove(n))),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('+2 ek'));
      await tester.pumpAndSettle();
      expect(find.text('6 ek · 12 KB'), findsOneWidget);

      // Sayfadaki son satırın "Kaldır"ı (çiplerdeki de aynı ipucuna sahip).
      await tester.tap(find.byTooltip('Kaldır').last);
      await tester.pumpAndSettle();
      expect(find.text('5 ek · 10 KB'), findsOneWidget);
      expect(find.text('f.png'), findsNothing);
    });

    testWidgets('hazırlanan ek listede "Hazırlanıyor…" gösterir ve açılmaz', (
      tester,
    ) async {
      var opened = 0;
      await pump(tester, [
        for (var i = 1; i <= 5; i++) entry('x$i.png', onOpen: (_) => opened++),
        entry('bekleyen.png', pending: true, onOpen: (_) => opened++),
      ]);
      await tester.tap(find.text('+2 ek'));
      // Yükleniyor göstergesi sonsuz animasyon: pumpAndSettle bitmez.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Hazırlanıyor…'), findsOneWidget);
      await tester.ensureVisible(find.text('bekleyen.png').last);
      await tester.tap(find.text('bekleyen.png').last);
      await tester.pump();
      expect(opened, 0);
    });
  });
}
