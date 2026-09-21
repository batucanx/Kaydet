import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/compose/send_feedback.dart';

void main() {
  late StreamController<OutboxState?> states;

  setUp(() => states = StreamController<OutboxState?>());
  tearDown(() => states.close());

  Future<OverlayState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const Scaffold()),
    );
    return tester.state<OverlayState>(find.byType(Overlay).first);
  }

  /// Bir bildirimin giriş animasyonunu (ve varsa öncekinin çıkışını) oynatır.
  Future<void> pumpTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  /// Ekrandaki bildirimin süresi dolup kapanmasını bekler.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 30));
    await pumpTransition(tester);
  }

  group('SendFeedback', () {
    testWidgets('önce "gönderiliyor", sonuç gelince "gönderildi" der', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      SendFeedback.track(overlay, states.stream);
      await pumpTransition(tester);
      expect(find.text(SendFeedback.sendingMessage), findsOneWidget);

      // Kuyrukta bekleme ya da gönderim sürerken kullanıcıya yeni bir şey
      // söylenmez.
      states
        ..add(OutboxState.queued)
        ..add(OutboxState.sending);
      await pumpTransition(tester);
      expect(find.text(SendFeedback.sendingMessage), findsOneWidget);
      expect(find.text(SendFeedback.sentMessage), findsNothing);

      states.add(OutboxState.sent);
      await pumpTransition(tester);
      expect(find.text(SendFeedback.sentMessage), findsOneWidget);
      expect(find.text(SendFeedback.sendingMessage), findsNothing);

      await drain(tester);
    });

    testWidgets('gönderim başarısız olursa "gönderilemedi" der', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      SendFeedback.track(overlay, states.stream);
      await pumpTransition(tester);

      states.add(OutboxState.failed);
      await pumpTransition(tester);

      expect(find.text(SendFeedback.failedMessage), findsOneWidget);
      expect(find.text(SendFeedback.sendingMessage), findsNothing);
      expect(find.text(SendFeedback.sentMessage), findsNothing);

      await drain(tester);
    });

    testWidgets('sonuç gelmezse süre dolunca bekleme durumunu söyler', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);

      SendFeedback.track(
        overlay,
        states.stream,
        patience: const Duration(seconds: 2),
      );
      await pumpTransition(tester);
      states.add(OutboxState.queued);
      await pumpTransition(tester);
      expect(find.text(SendFeedback.sendingMessage), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await pumpTransition(tester);

      expect(find.text(SendFeedback.waitingMessage), findsOneWidget);
      expect(find.text(SendFeedback.sendingMessage), findsNothing);

      // İzleme bırakıldı: sonradan gelen "gönderildi" artık bildirilmez.
      states.add(OutboxState.sent);
      await pumpTransition(tester);
      expect(find.text(SendFeedback.sentMessage), findsNothing);

      await drain(tester);
    });

    testWidgets('ileti silinirse hiçbir sonuç bildirilmez', (tester) async {
      final overlay = await pumpHost(tester);

      SendFeedback.track(overlay, states.stream);
      await pumpTransition(tester);

      states.add(null);
      await pumpTransition(tester);

      expect(find.text(SendFeedback.sendingMessage), findsNothing);
      expect(find.text(SendFeedback.sentMessage), findsNothing);
      expect(find.text(SendFeedback.failedMessage), findsNothing);
    });
  });
}
