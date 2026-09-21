import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/core/widgets/kaydet_notice.dart';

void main() {
  Future<OverlayState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const Scaffold()),
    );
    return tester.state<OverlayState>(find.byType(Overlay).first);
  }

  /// Girdiyi ekler ve giriş animasyonunun bitmesini bekler. Bir animasyonun
  /// süresi ilk karede değil, ilk "tick"ten sonra işlemeye başlar — bu yüzden
  /// önce kısa bir kare, sonra tam süre.
  Future<void> pumpIn(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Girdi kaldırılana kadar çıkış animasyonunu oynatır.
  Future<void> pumpOut(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  double opacityOf(WidgetTester tester) {
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Merhaba'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    return fade.opacity.value;
  }

  group('KaydetNotice', () {
    testWidgets('süre dolunca sert kesilmez, yumuşakça solarak kapanır', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      KaydetNotice.show(
        overlay,
        message: 'Merhaba',
        duration: const Duration(seconds: 1),
      );
      await pumpIn(tester);
      expect(find.text('Merhaba'), findsOneWidget);
      expect(opacityOf(tester), 1.0);

      // Süre dolar, çıkış başlar: Material 3 SnackBar'ın aksine opaklık ara
      // değerlerden geçmeli (bkz. `KaydetNotice`nin belgesi).
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacityOf(tester), inExclusiveRange(0.0, 1.0));

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Merhaba'), findsNothing);
    });

    testWidgets('eylem düğmesi çağrılır ve bildirim kapanır', (tester) async {
      final overlay = await pumpHost(tester);
      var pressed = 0;

      KaydetNotice.show(
        overlay,
        message: 'Merhaba',
        actionLabel: 'Sil',
        onAction: () => pressed++,
      );
      await pumpIn(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      expect(pressed, 1);

      await pumpOut(tester);
      expect(find.text('Merhaba'), findsNothing);
    });

    testWidgets('bottomInset bildirimi alt öğenin üstünde tutar', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      // Örnek: FAB (56) + kenar boşluğu (16) = 72 — bildirimin altı bunun
      // 8 dp üstünde olmalı.
      KaydetNotice.show(overlay, message: 'Merhaba', bottomInset: 72);
      await pumpIn(tester);

      final card = find
          .ancestor(of: find.text('Merhaba'), matching: find.byType(Material))
          .first;
      final screenBottom = tester.getRect(find.byType(Scaffold)).bottom;
      expect(tester.getRect(card).bottom, closeTo(screenBottom - 80, 0.01));
    });

    testWidgets('yeni bildirim göründüğünde öncekinin yerini alır', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      KaydetNotice.show(overlay, message: 'Merhaba');
      await pumpIn(tester);
      KaydetNotice.show(overlay, message: 'Başka');
      await pumpIn(tester);
      await pumpOut(tester);

      expect(find.text('Merhaba'), findsNothing);
      expect(find.text('Başka'), findsOneWidget);
    });
  });
}
