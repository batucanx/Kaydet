import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Senkronizasyon sıklığı.
///
/// Android'de arka plan görevlerinin alt sınırı 15 dakikadır; "anlık"
/// seçeneği yalnızca uygulama önplandayken (IMAP IDLE ile) gerçekten
/// anlıktır. Arayüzde bu dürüstçe yazılır.
enum SyncFrequency {
  push(Duration(minutes: 15), 'Anlık (uygulama açıkken)'),
  min15(Duration(minutes: 15), '15 dakikada bir'),
  min30(Duration(minutes: 30), '30 dakikada bir'),
  hour1(Duration(hours: 1), 'Saatte bir'),
  manual(Duration.zero, 'Yalnızca elle');

  const SyncFrequency(this.interval, this.label);
  final Duration interval;
  final String label;

  bool get isBackgroundEnabled => this != SyncFrequency.manual;
}

/// Uygulama tercihleri.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.notificationsEnabled = true,
    this.syncFrequency = SyncFrequency.push,
    this.showRemoteImages = false,
    this.confirmBeforeDelete = true,
    this.markSeenDelayMs = 1500,
  });

  final ThemeMode themeMode;
  final bool notificationsEnabled;
  final SyncFrequency syncFrequency;

  /// Uzak görseller varsayılan olarak engellenir: yüklenirse gönderen
  /// iletinin okunduğunu öğrenir (izleme pikseli).
  final bool showRemoteImages;
  final bool confirmBeforeDelete;

  /// Mail açıldıktan kaç ms sonra okundu işaretlenir.
  ///
  /// Anında işaretlenirse, yanlış iletiye dokunup hemen geri çıkan kullanıcı
  /// o iletiyi okunmuş bulur.
  final int markSeenDelayMs;

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? notificationsEnabled,
    SyncFrequency? syncFrequency,
    bool? showRemoteImages,
    bool? confirmBeforeDelete,
    int? markSeenDelayMs,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        syncFrequency: syncFrequency ?? this.syncFrequency,
        showRemoteImages: showRemoteImages ?? this.showRemoteImages,
        confirmBeforeDelete: confirmBeforeDelete ?? this.confirmBeforeDelete,
        markSeenDelayMs: markSeenDelayMs ?? this.markSeenDelayMs,
      );
}

/// Tercihlerin kalıcı saklanması.
class AppSettingsStore {
  AppSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kTheme = 'kaydet.themeMode';
  static const _kNotifications = 'kaydet.notifications';
  static const _kSync = 'kaydet.syncFrequency';
  static const _kRemoteImages = 'kaydet.showRemoteImages';
  static const _kConfirmDelete = 'kaydet.confirmDelete';

  static Future<AppSettingsStore> create() async =>
      AppSettingsStore(await SharedPreferences.getInstance());

  AppSettings read() {
    final themeIndex = _prefs.getInt(_kTheme);
    final syncIndex = _prefs.getInt(_kSync);
    return AppSettings(
      themeMode: themeIndex == null
          ? ThemeMode.dark
          : ThemeMode.values[themeIndex.clamp(0, ThemeMode.values.length - 1)],
      notificationsEnabled: _prefs.getBool(_kNotifications) ?? true,
      syncFrequency: syncIndex == null
          ? SyncFrequency.push
          : SyncFrequency
              .values[syncIndex.clamp(0, SyncFrequency.values.length - 1)],
      showRemoteImages: _prefs.getBool(_kRemoteImages) ?? false,
      confirmBeforeDelete: _prefs.getBool(_kConfirmDelete) ?? true,
    );
  }

  Future<void> write(AppSettings settings) async {
    await _prefs.setInt(_kTheme, settings.themeMode.index);
    await _prefs.setBool(_kNotifications, settings.notificationsEnabled);
    await _prefs.setInt(_kSync, settings.syncFrequency.index);
    await _prefs.setBool(_kRemoteImages, settings.showRemoteImages);
    await _prefs.setBool(_kConfirmDelete, settings.confirmBeforeDelete);
  }
}
