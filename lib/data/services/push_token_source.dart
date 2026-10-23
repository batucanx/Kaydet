import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'notification_service.dart';

/// Cihazın uzak-push token'ının kaynağı (iOS'ta APNs, Android'de FCM).
///
/// `RemotePushController` bunu platformdan bağımsız kullanır; testlerde sahtesi
/// verilir (bkz. `pushTokenSourceProvider`).
abstract interface class PushTokenSource {
  /// Geçerli token. Alınamıyorsa (iOS'ta henüz gelmedi; Android'de Firebase
  /// yapılandırılmamış ya da cihazda Google Play hizmetleri yok) `null`.
  Future<String?> load();

  /// Token yenilendiğinde yayın yapar.
  Stream<String> get refreshes;
}

/// iOS: token `AppDelegate.swift`ten kanalla gelir (bkz. `NotificationService`).
class ApnsTokenSource implements PushTokenSource {
  const ApnsTokenSource();

  @override
  Future<String?> load() async => NotificationService.latestApnsToken;

  @override
  Stream<String> get refreshes => NotificationService.apnsTokens;
}

/// Android: FCM token'ı `FcmChannel.kt` üzerinden gelir.
///
/// Kanal, native tarafın çağrıları (`onToken`, `onPush`) kaçmasın diye
/// uygulama açılırken [install] ile kurulur.
class AndroidPushChannel implements PushTokenSource {
  AndroidPushChannel._();

  static final AndroidPushChannel instance = AndroidPushChannel._();

  static const MethodChannel _channel = MethodChannel(
    'tr.com.kaydetmail/fcm',
  );

  final StreamController<String> _tokens = StreamController<String>.broadcast();
  final StreamController<void> _syncs = StreamController<void>.broadcast();

  /// Arka plan işçisi bir eşitlemeyi bitirdiğinde yayın yapar (başka isolate
  /// veritabanına yazdı; Drift akışları bunu kendiliğinden görmez).
  Stream<void> get backgroundSyncs => _syncs.stream;

  /// Ön plandaki (aktif) hesabı native tarafa bildirir. Ana isolate yalnızca
  /// bu hesabı eşitler; başka hesabın push'u native tarafta arka plan
  /// işçisine yönlendirilir (bkz. `FcmChannel.deliverPushToForeground`).
  Future<void> setActiveAccount(int? accountId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setActiveAccount', accountId);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  bool _installed = false;

  /// Native → Dart çağrılarını dinlemeye başlar. Yalnızca Android'de etkilidir.
  void install() {
    if (_installed || !Platform.isAndroid) return;
    _installed = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onToken':
          final token = call.arguments;
          if (token is String && token.isNotEmpty) _tokens.add(token);
        case 'onSynced':
          _syncs.add(null);
        case 'onPush':
          // Uygulama önde: eşitleme ana isolate'te yapılır ki Drift akışları
          // listeyi anında güncellesin (iOS'taki `onRemotePush` ile aynı).
          final arguments = call.arguments;
          final accountId = arguments is Map ? arguments['accountId'] : null;
          NotificationService.deliverRemotePush(
            accountId is int ? accountId : null,
          );
      }
    });
  }

  @override
  Future<String?> load() async {
    if (!Platform.isAndroid) return null;
    try {
      final token = await _channel.invokeMethod<String>('getToken');
      return (token == null || token.isEmpty) ? null : token;
    } on PlatformException catch (error) {
      debugPrint('FCM token alınamadı: ${error.code}');
      return null;
    } on MissingPluginException catch (_) {
      return null; // arka plan isolate'i ya da test
    }
  }

  @override
  Stream<String> get refreshes => _tokens.stream;
}
