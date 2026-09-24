import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/core/navigation/kaydet_route.dart';

/// Kendi durumunu ve kaç kez kurulduğunu tutan basit bir ekran içeriği.
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int initCount = 0;

  int _taps = 0;

  @override
  void initState() {
    super.initState();
    initCount++;
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: GestureDetector(
      onTap: () => setState(() => _taps++),
      child: Text('dokunuş: $_taps'),
    ),
  );
}

void main() {
  setUp(() => _ProbeState.initCount = 0);
  tearDown(() => KaydetRoute.pushProgress.value = 0);

  Future<void> pumpProbe(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: KaydetDepthCoverEffect(child: _Probe())),
    ),
  );

  group('KaydetDepthCoverEffect', () {
    testWidgets('itme ilerlemesi değişince altındaki ekran yeniden kurulmaz',
        (tester) async {
      // Ağaç şekli ilerlemeye göre değişirse çerçeve alt ağacın TAMAMINI söküp
      // yeniden kurar: durum sıfırlanır ve o ağaçtan yakalanmış her
      // `BuildContext` `mounted` olmaktan çıkar (yazma ekranı kapanınca
      // "taslak kaydedildi" bildirimi bu yüzden hiç gösterilmiyordu).
      await pumpProbe(tester);

      await tester.tap(find.text('dokunuş: 0'));
      await tester.pump();
      expect(find.text('dokunuş: 1'), findsOneWidget);

      for (final progress in [0.4, 1.0, 0.5, 0.0]) {
        KaydetRoute.pushProgress.value = progress;
        await tester.pump();
        expect(
          find.text('dokunuş: 1'),
          findsOneWidget,
          reason: 'ilerleme $progress iken alt ağacın durumu korunmalı',
        );
      }
      expect(_ProbeState.initCount, 1);
    });

    testWidgets('karartma katmanı yalnızca geçiş sürerken vardır',
        (tester) async {
      await pumpProbe(tester);
      final overlay = find.descendant(
        of: find.byType(KaydetDepthCoverEffect),
        matching: find.byType(IgnorePointer),
      );
      expect(overlay, findsNothing);

      KaydetRoute.pushProgress.value = 0.5;
      await tester.pump();
      expect(overlay, findsOneWidget);

      KaydetRoute.pushProgress.value = 0;
      await tester.pump();
      expect(overlay, findsNothing);
    });
  });

  group('KaydetTransitionStyle.compose', () {
    test('geçiş süreleri Motion.compose (280ms) ve Motion.composeBack (220ms)', () {
      final route = KaydetRoute<void>(
        builder: (_) => const SizedBox(),
        transitionStyle: KaydetTransitionStyle.compose,
      );
      expect(route.transitionDuration, const Duration(milliseconds: 280));
      expect(route.reverseTransitionDuration, const Duration(milliseconds: 220));
    });

    testWidgets('fade, subtle scale ve mikro dikey hareket ile akıcı açılır ve geri döner',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  KaydetRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Yeni İleti Sayfası')),
                    transitionStyle: KaydetTransitionStyle.compose,
                  ),
                ),
                child: const Text('Yeni İleti Aç'),
              ),
            ),
          ),
        ),
      );

      // Başlangıç durumu
      expect(find.text('Yeni İleti Aç'), findsOneWidget);
      expect(find.text('Yeni İleti Sayfası'), findsNothing);
      expect(KaydetRoute.pushProgress.value, 0);

      // Butona dokun
      await tester.tap(find.text('Yeni İleti Aç'));
      await tester.pump(); // Route açılışı başlar

      // Compose geçişinde pushProgress 0 kalmalı (arka plan kararmamalı/küçülmemeli)
      expect(KaydetRoute.pushProgress.value, 0);

      // Geçiş widget'ları mevcut mu?
      final fadeFinder = find.descendant(
        of: find.byType(MaterialApp),
        matching: find.byType(FadeTransition),
      );
      expect(fadeFinder, findsWidgets);

      // Yarım süre ilerlet
      await tester.pump(const Duration(milliseconds: 140));
      expect(find.text('Yeni İleti Sayfası'), findsOneWidget);
      expect(KaydetRoute.pushProgress.value, 0);

      // Tam süreye ulaş (280ms)
      await tester.pumpAndSettle();
      expect(find.text('Yeni İleti Sayfası'), findsOneWidget);
      expect(KaydetRoute.pushProgress.value, 0);

      // Geri dön
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();

      // Kapanış animasyonunu tamamla
      await tester.pumpAndSettle();
      expect(find.text('Yeni İleti Sayfası'), findsNothing);
      expect(find.text('Yeni İleti Aç'), findsOneWidget);
    });
  });
}
