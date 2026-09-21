import 'package:flutter/material.dart';

/// Bildirime dokunma gibi widget ağacı dışından gezinme gerektiren
/// durumlar için kök gezinme anahtarı (bkz. `NotificationNavigator`).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
