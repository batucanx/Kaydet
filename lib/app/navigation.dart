import 'package:flutter/material.dart';

/// Bildirime dokunma gibi widget ağacı dışından gezinme gerektiren
/// durumlar için kök gezinme anahtarı (bkz. `NotificationNavigator`).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Ana kabuğun (`AppShell`) iskelesi: yan menü (drawer) dışarıdan
/// kapatılabilsin diye (bkz. `NotificationNavigator.resetToInboxRoot`).
final GlobalKey<ScaffoldState> shellScaffoldKey = GlobalKey<ScaffoldState>();

/// Ana kabuk ekranda mı? Soğuk açılışta bildirim gezintisi, kabuk (açılış
/// animasyonu ve oturum kontrolü bittikten sonra) hazır olana dek bekler.
final ValueNotifier<bool> appShellReady = ValueNotifier<bool>(false);
