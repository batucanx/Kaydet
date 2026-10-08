import 'dart:io';

import 'push_backend_config.dart';

/// iOS'ta sunucu tabanlı push yapılandırılmışsa yeni ileti bildirimini APNs
/// gösterir; yerel bildirim de üretmek aynı iletiyi ikinci kez bildirir.
///
/// Ana ve arka plan isolate'leri tarafından paylaşıldığından bağımlılığı
/// azdır (Riverpod/sağlayıcı yok).
bool get remotePushShowsAlerts =>
    Platform.isIOS &&
    PushBackendSecrets.baseUrl.isNotEmpty &&
    PushBackendSecrets.apiKey.isNotEmpty;
