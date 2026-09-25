import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/remote_push_sync.dart';
import '../data/services/notification_service.dart';
import '../data/services/push_backend_client.dart';
import 'providers.dart';

/// Sunucu tabanlı anlık bildirim: yalnızca iOS'ta ve derleme zamanında
/// `PUSH_BACKEND_URL` / `PUSH_API_KEY` verilmişse vardır; aksi hâlde `null`
/// döner ve özelliğin tamamı (ayar anahtarı dahil) görünmez/etkisizdir.
final remotePushSyncProvider = Provider<RemotePushSync?>((ref) {
  final config = PushBackendConfig.compiled;
  if (config == null || !Platform.isIOS) return null;
  final client = HttpPushBackendClient(config);
  ref.onDispose(client.close);
  return RemotePushSync(
    api: client,
    store: SharedPrefsRegistrationStore(
      ref.watch(settingsStoreProvider).preferences,
    ),
    readPassword: ref.watch(secureStoreProvider).readPassword,
    environment: _apnsEnvironment,
    log: kDebugMode ? (message) => debugPrint('RemotePush: $message') : null,
  );
});

/// Token'ın hangi APNs ortamına ait olduğu.
///
/// Varsayılan: debug derlemesi sandbox, TestFlight/App Store production
/// (bkz. ios/Runner.xcodeproj `APS_ENVIRONMENT`). Kendi geliştirici
/// sertifikanla imzalanmış bir RELEASE derlemesi ise sandbox token üretir;
/// bu durumda `--dart-define=PUSH_APNS_ENV=development` verilmelidir, yoksa
/// sunucu token'ı yanlış Apple adresine gönderip `BadDeviceToken` alır.
String get _apnsEnvironment {
  const override = String.fromEnvironment('PUSH_APNS_ENV');
  if (override == 'development' || override == 'production') return override;
  return kDebugMode ? 'development' : 'production';
}

/// APNs token'ının geldiği yer; testlerde sahtesi verilir.
final apnsTokenSourceProvider =
    Provider<({String? latest, Stream<String> stream})>(
      (ref) => (
        latest: NotificationService.latestApnsToken,
        stream: NotificationService.apnsTokens,
      ),
    );

/// Cihazdaki hesapları push sunucusuyla eşler (bkz. `RemotePushSync`).
///
/// Şu olaylarda çalışır: APNs token'ı geldiğinde, hesap eklenip silindiğinde
/// ve kullanıcı ayarı değiştirdiğinde. Başarısız olursa dakikada bir yeniden
/// dener; böylece ağ kesintisi kaydı kalıcı olarak kaçırmaz.
class RemotePushController extends Notifier<void> {
  static const _retryDelay = Duration(minutes: 1);

  String? _token;
  bool _running = false;
  bool _runAgain = false;
  final Set<int> _force = {};
  Timer? _retryTimer;

  @override
  void build() {
    final sync = ref.watch(remotePushSyncProvider);
    if (sync == null) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint(
          'RemotePush: KAPALI - PUSH_BACKEND_URL / PUSH_API_KEY verilmemis '
          '(flutter run komutuna --dart-define ekleyin)',
        );
      }
      return;
    }

    final source = ref.watch(apnsTokenSourceProvider);
    _token = source.latest;
    final subscription = source.stream.listen((token) {
      _token = token;
      _trigger();
    });
    ref.onDispose(() {
      subscription.cancel();
      _retryTimer?.cancel();
    });

    ref.listen(allAccountsProvider, (_, _) => _trigger());
    ref.listen(
      settingsProvider.select(
        (s) => s.remotePushEnabled && s.notificationsEnabled,
      ),
      (_, _) => _trigger(),
    );
    _trigger();
  }

  /// [accountId]'nin şifresi değişti: aynı sunucu ayarlarıyla da olsa yeniden
  /// gönderilmeli.
  void passwordChanged(int accountId) {
    _force.add(accountId);
    _trigger();
  }

  void _trigger() {
    _retryTimer?.cancel();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_running) {
      _runAgain = true;
      return;
    }
    _running = true;
    try {
      do {
        _runAgain = false;
        await _syncOnce();
      } while (_runAgain);
    } finally {
      _running = false;
    }
  }

  Future<void> _syncOnce() async {
    final sync = ref.read(remotePushSyncProvider);
    final accounts = ref.read(allAccountsProvider).value;
    if (sync == null || accounts == null) return; // hesaplar henüz yüklenmedi

    final settings = ref.read(settingsProvider);
    final force = {..._force};
    final enabled = settings.remotePushEnabled && settings.notificationsEnabled;
    if (kDebugMode) {
      debugPrint(
        'RemotePush: eşitleme (ayar açık: $enabled, '
        'APNs token: ${_token != null ? 'var' : 'YOK'}, '
        'hesap: ${accounts.length})',
      );
    }
    var ok = false;
    try {
      ok = await sync.sync(
        token: _token,
        enabled: enabled,
        accounts: accounts,
        force: force,
      );
    } on Object catch (_) {
      // Beklenmeyen hata da bildirim altyapısını (IMAP eşitlemesi, yerel
      // bildirimler) etkilememeli; yeniden denenir.
    }
    if (ok) {
      _force.removeAll(force);
    } else {
      _retryTimer = Timer(_retryDelay, _trigger);
    }
  }
}

final remotePushControllerProvider =
    NotifierProvider<RemotePushController, void>(RemotePushController.new);
