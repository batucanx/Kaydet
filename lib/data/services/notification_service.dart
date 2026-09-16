import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../database/app_database.dart';

/// Yeni ileti bildirimleri.
///
/// Bildirim metni yalnızca gönderen ve konu içerir; ileti gövdesi kilit
/// ekranına düşmez.
class NotificationService {
  NotificationService([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialised = false;

  static const String _channelId = 'kaydet_mail';
  static const String _channelName = 'Yeni iletiler';
  static const String _channelDescription =
      'Gelen kutusuna yeni bir ileti düştüğünde bildirir.';

  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
    _channelId,
    _channelName,
    channelDescription: _channelDescription,
    importance: Importance.high,
    priority: Priority.high,
    groupKey: 'kaydet_inbox',
    styleInformation: BigTextStyleInformation(''),
  );

  Future<void> initialize() async {
    if (_initialised) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _initialised = true;
  }

  /// Android 13+ bildirim iznini ister.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// Tek bir ileti için bildirim gösterir.
  Future<void> showNewMail(MessageRow message) async {
    await initialize();
    final sender = message.fromName.trim().isNotEmpty
        ? message.fromName
        : message.fromEmail;
    final subject =
        message.subject.trim().isEmpty ? '(konu yok)' : message.subject;

    await _plugin.show(
      id: message.id,
      title: sender,
      body: subject,
      notificationDetails: const NotificationDetails(android: _androidDetails),
      payload: 'message:${message.id}',
    );
  }

  /// Birden fazla yeni ileti için özet bildirimi.
  Future<void> showSummary(int count) async {
    if (count <= 1) return;
    await initialize();
    await _plugin.show(
      id: 0,
      title: 'Kaydet',
      body: '$count yeni ileti',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          groupKey: 'kaydet_inbox',
          setAsGroupSummary: true,
        ),
      ),
    );
  }

  Future<void> cancelAll() async {
    await initialize();
    await _plugin.cancelAll();
  }
}
