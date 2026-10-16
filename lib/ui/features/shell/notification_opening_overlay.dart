import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../app/notification_navigator.dart';
import '../../core/theme/tokens.dart';

/// Bildirimden açılan ileti getirilirken Gelen Kutusu'nun üstünde görünen
/// "açılıyor" katmanı.
///
/// Hedef ileti yerelde varsa saniyenin çok altında açıldığı için katman
/// [_showAfter] dolmadan görünmez (yanıp sönmez). İleti sunucudan getirilirken
/// (birkaç saniye) kullanıcı Gelen Kutusu'nda bir şeye dokunup niyeti bozmasın
/// diye dokunuşları keser; "Vazgeç" ile iptal edilebilir.
class NotificationOpeningOverlay extends ConsumerStatefulWidget {
  const NotificationOpeningOverlay({super.key});

  @override
  ConsumerState<NotificationOpeningOverlay> createState() =>
      _NotificationOpeningOverlayState();
}

class _NotificationOpeningOverlayState
    extends ConsumerState<NotificationOpeningOverlay> {
  static const Duration _showAfter = Duration(milliseconds: 350);

  late final Listenable _active = Listenable.merge([
    notificationOpening,
    appShellReady,
  ]);
  Timer? _delay;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _active.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    _active.removeListener(_sync);
    _delay?.cancel();
    super.dispose();
  }

  void _sync() {
    final wanted = notificationOpening.value && appShellReady.value;
    if (!wanted) {
      _delay?.cancel();
      _delay = null;
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (_visible || _delay != null) return;
    _delay = Timer(_showAfter, () {
      _delay = null;
      if (!mounted) return;
      if (notificationOpening.value && appShellReady.value) {
        setState(() => _visible = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final t = context.tokens;
    return Positioned.fill(
      child: Material(
        color: t.bg.withValues(alpha: 0.88),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              const SizedBox(height: 16),
              Text(
                'İleti açılıyor…',
                style: TextStyle(color: t.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    ref.read(notificationNavigatorProvider).cancelOpening(),
                child: Text('Vazgeç', style: TextStyle(color: t.accent)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
