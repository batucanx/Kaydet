import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/notification_service.dart';
import '../ui/core/navigation/kaydet_route.dart';
import '../ui/features/compose/compose_launcher.dart';
import '../ui/features/compose/compose_screen.dart' show ComposeMode;
import '../ui/features/mail_detail/mail_detail_screen.dart';
import 'navigation.dart';
import 'providers.dart';

/// Bildirime dokunulunca ilgili iletiye gider; "Yanıtla"ya dokunulunca o
/// iletinin yanıt ekranını açar.
///
/// `NotificationService`'in arka plan işleyicisi (Arşivle/Sil) ayrı bir
/// izole'de çalışır ve buraya bağlanamaz (bkz. `background_sync.dart` →
/// `notificationBackgroundHandler`); bu sınıf yalnızca uygulamayı öne getiren
/// dokunuşları — gövde ve "Yanıtla" — uygulama canlıyken ve soğuk
/// başlangıçta ele alır.
class NotificationNavigator {
  NotificationNavigator._(this._ref) {
    _sub = NotificationService.taps.listen(_handle);
  }

  final Ref _ref;
  late final StreamSubscription<NotificationTap> _sub;

  void _dispose() => _sub.cancel();

  /// Uygulama bir bildirime dokunularak açıldıysa (soğuk başlangıç) aynı
  /// hedefe gider. İlk kare çizildikten sonra çağrılmalı.
  Future<void> handleColdStart() async {
    final details =
        await _ref.read(notificationServiceProvider).appLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final tap = NotificationService.tapFromResponse(
      details!.notificationResponse,
    );
    if (tap != null) await _handle(tap);
  }

  Future<void> _handle(NotificationTap tap) async {
    final db = _ref.read(databaseProvider);
    final message = await db.messageById(tap.messageId);
    if (message == null) return;

    if (message.accountId != _ref.read(accountIdProvider)) {
      await _ref
          .read(accountRepositoryProvider)
          .switchAccount(message.accountId);
    }
    _ref.read(activeTabProvider.notifier).select(0);
    _ref
        .read(selectedFolderRawProvider.notifier)
        .select(SelectedFolder.mailbox(message.mailboxId));

    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    switch (tap.kind) {
      case NotificationTapKind.open:
        unawaited(
          navigator.push<void>(
            KaydetRoute<void>(
              builder: (_) => MailDetailScreen(messageId: tap.messageId),
            ),
          ),
        );
      case NotificationTapKind.reply:
        final repository = _ref.read(mailRepositoryProvider);
        unawaited(
          openComposeFromNavigator(
            navigator,
            replyToId: tap.messageId,
            mode: ComposeMode.reply,
            repository: repository,
          ),
        );
    }
  }
}

final notificationNavigatorProvider = Provider<NotificationNavigator>((ref) {
  final navigator = NotificationNavigator._(ref);
  ref.onDispose(navigator._dispose);
  return navigator;
});
