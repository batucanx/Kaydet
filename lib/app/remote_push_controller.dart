import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/remote_push_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/app_settings.dart';
import '../data/services/install_credentials.dart';
import '../data/services/push_backend_client.dart';
import '../data/services/push_token_source.dart';
import 'install_credentials_provider.dart';
import 'providers.dart';
import 'push_backend_config.dart';

/// Sunucu tabanlı anlık bildirim (iOS: APNs, Android: FCM). `PushBackendSecrets`
/// doldurulmamışsa (bkz. `push_backend_config.dart`) ya da platform
/// desteklenmiyorsa `null` döner ve özelliğin tamamı etkisizdir.
final remotePushSyncProvider = Provider<RemotePushSync?>((ref) {
  final built = buildRemotePushSync(
    preferences: ref.watch(settingsStoreProvider).preferences,
    readPassword: ref.watch(secureStoreProvider).readPassword,
    credentials: ref.watch(installCredentialsProvider),
    log: kDebugMode ? (message) => debugPrint('RemotePush: $message') : null,
  );
  if (built == null) return null;
  ref.onDispose(built.dispose);
  return built.sync;
});

/// [RemotePushSync]i ve onun HTTP istemcisini kurar; backend yapılandırılmamışsa
/// ya da platform desteklenmiyorsa `null`. Ana isolate (sağlayıcı) ve arka plan
/// isolate'leri (bkz. `reconcileRemotePushInBackground`) aynı kurulumu paylaşır.
({RemotePushSync sync, void Function() dispose})? buildRemotePushSync({
  required SharedPreferences preferences,
  required Future<String?> Function(int accountId) readPassword,
  required InstallCredentialsSource credentials,
  void Function(String message)? log,
}) {
  if (!Platform.isIOS && !Platform.isAndroid) return null;
  if (PushBackendSecrets.baseUrl.isEmpty || PushBackendSecrets.apiKey.isEmpty) {
    return null;
  }
  final client = HttpPushBackendClient(
    PushBackendConfig(
      baseUrl: PushBackendSecrets.baseUrl,
      apiKey: PushBackendSecrets.apiKey,
      credentials: credentials,
    ),
    platform: Platform.isIOS ? 'ios' : 'android',
  );
  final sync = RemotePushSync(
    api: client,
    store: SharedPrefsRegistrationStore(preferences),
    readPassword: readPassword,
    // Android'de ortam kavramı yoktur; sunucu satırı `production` yazar.
    environment: Platform.isIOS ? _apnsEnvironment : 'production',
    log: log,
  );
  return (sync: sync, dispose: client.close);
}

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

/// Push token'ının geldiği yer; testlerde sahtesi verilir.
final pushTokenSourceProvider = Provider<PushTokenSource>(
  (ref) => Platform.isAndroid
      ? AndroidPushChannel.instance
      : const ApnsTokenSource(),
);

/// Kullanıcının ayarlarına göre cihazın sunucuya kayıtlı OLMASI gerekir mi?
///
/// iOS: bildirimler açıksa (sunucu, APNs ile hem uyandırır hem bildirimi
/// gösterir). Android: bildirimler açık VE sıklık "Anlık" ise; daha seyrek
/// bir sıklık seçen kullanıcının şifresi sunucuya GİTMEZ, yalnızca cihaz
/// periyodik eşitler (bkz. `BackgroundSync`).
bool wantsServerPush(AppSettings settings) =>
    settings.notificationsEnabled &&
    (!Platform.isAndroid || settings.syncFrequency == SyncFrequency.push);

/// Sunucu kaydı kullanıcıya bir gizlilik beyanı gerektiriyor mu? (Şifre
/// sunucuya gidecek mi?)
final serverPushInUseProvider = Provider<bool>((ref) {
  if (ref.watch(remotePushSyncProvider) == null) return false;
  return wantsServerPush(ref.watch(settingsProvider));
});

/// Sunucu tabanlı push'un cihazdaki durumu.
enum ServerPushState {
  /// Bu cihazda kullanılamıyor: backend yapılandırılmamış, Firebase/Google
  /// Play hizmetleri yok ya da token alınamadı. Android'de bu durumda ön plan
  /// servisi (IDLE) devreye girer.
  unavailable,

  /// Kullanıcı ayarları sunucu push'unu istemiyor (bildirim kapalı ya da
  /// Android'de "Anlık" dışı sıklık).
  disabled,

  /// Henüz ilk kayıt denemesi sonuçlanmadı.
  pending,

  /// Hesaplar sunucuya kayıtlı; push gelir.
  active,

  /// Son kayıt denemesi başarısız (sunucu/ağ). Android'de ön plan servisi
  /// yedek olarak çalışır; deneme dakikada bir sürer.
  failing,
}

/// Cihazdaki hesapları push sunucusuyla eşler (bkz. `RemotePushSync`).
///
/// Şu olaylarda çalışır: push token'ı geldiğinde/yenilendiğinde, hesap
/// eklenip silindiğinde, kullanıcı bildirim ayarını değiştirdiğinde ve uygulama
/// öne geldiğinde. Başarısız olursa dakikada bir yeniden dener; böylece ağ
/// kesintisi kaydı kalıcı olarak kaçırmaz.
///
/// Durumu [ServerPushState] olarak yayınlar; Android'de `PushController` ön
/// plan servisini bununla yönetir (sunucu push'u çalışıyorsa servis gereksiz).
class RemotePushController extends Notifier<ServerPushState> {
  static const _retryDelay = Duration(minutes: 1);

  String? _token;
  bool _tokenLoaded = false;
  bool _running = false;
  bool _runAgain = false;
  final Set<int> _force = {};
  Timer? _retryTimer;

  @override
  ServerPushState build() {
    final sync = ref.watch(remotePushSyncProvider);
    if (sync == null) {
      if (kDebugMode && (Platform.isIOS || Platform.isAndroid)) {
        debugPrint(
          'RemotePush: KAPALI - push_backend_config.dart doldurulmamış '
          '(bkz. backend/README.md "Uygulamaya bağlama")',
        );
      }
      return ServerPushState.unavailable;
    }

    final source = ref.watch(pushTokenSourceProvider);
    _token = null;
    _tokenLoaded = false;
    unawaited(
      source.load().then((token) {
        if (!ref.mounted) return;
        // Yükleme sürerken yenileme gelmişse daha yeni olan korunur.
        _token ??= token;
        _tokenLoaded = true;
        _trigger();
      }),
    );
    final subscription = source.refreshes.listen((token) {
      _token = token;
      _tokenLoaded = true;
      _trigger();
    });
    ref.onDispose(() {
      subscription.cancel();
      _retryTimer?.cancel();
    });

    ref.listen(allAccountsProvider, (_, _) => _trigger());
    ref.listen(
      settingsProvider.select((s) => (s.notificationsEnabled, s.syncFrequency)),
      (_, _) => _trigger(),
    );
    // Uygulama her ön plana döndüğünde sunucu kaydı doğrulanır: sunucu
    // yeniden dağıtılıp veritabanı sıfırlandıysa kullanıcı bildirim ayarını
    // kapatıp açmadan hesaplar kendiliğinden yeniden kaydedilir. Kayıtlar
    // eşitse `sync` yalnızca tek bir hafif GET yapar (bkz. `RemotePushSync`).
    final lifecycle = AppLifecycleListener(onResume: _trigger);
    ref.onDispose(lifecycle.dispose);
    return ServerPushState.pending;
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
      } while (_runAgain && ref.mounted);
    } finally {
      _running = false;
    }
  }

  Future<void> _syncOnce() async {
    final sync = ref.read(remotePushSyncProvider);
    final accounts = ref.read(allAccountsProvider).value;
    if (sync == null || accounts == null) return; // hesaplar henüz yüklenmedi

    final enabled = wantsServerPush(ref.read(settingsProvider));
    final force = {..._force};
    if (kDebugMode) {
      debugPrint(
        'RemotePush: eşitleme (ayar açık: $enabled, '
        'token: ${_token != null ? 'var' : 'YOK'}, '
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
    if (!ref.mounted) return;
    if (ok) {
      _force.removeAll(force);
    } else {
      _retryTimer = Timer(_retryDelay, _trigger);
    }

    state = !enabled
        ? ServerPushState.disabled
        : _token == null
        ? (_tokenLoaded ? ServerPushState.unavailable : ServerPushState.pending)
        : ok
        ? ServerPushState.active
        : ServerPushState.failing;
  }
}

final remotePushControllerProvider =
    NotifierProvider<RemotePushController, ServerPushState>(
      RemotePushController.new,
    );
