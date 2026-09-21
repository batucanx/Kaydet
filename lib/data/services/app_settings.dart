import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Senkronizasyon sıklığı.
///
/// Android'de arka plan görevlerinin (WorkManager) alt sınırı 15 dakikadır.
/// "Anlık" seçeneği bunu aşar: Android ön plan servisi içinde her hesabın
/// Gelen Kutusu IMAP IDLE ile sürekli dinlenir (bkz. `PushService`). Servis
/// çalışırken 15 dakikalık görev yalnızca yedek olarak sürer. Diğer
/// seçeneklerde servis kapalıdır ve yalnızca periyodik görev çalışır.
///
/// SIRALAMA ÖNEMLİ: tercih `index` olarak saklanır; yeni değerler SONA eklenir.
enum SyncFrequency {
  push(Duration(minutes: 15), 'Anlık'),
  min15(Duration(minutes: 15), '15 dakikada bir'),
  min30(Duration(minutes: 30), '30 dakikada bir'),
  hour1(Duration(hours: 1), 'Saatte bir'),
  manual(Duration.zero, 'Yalnızca elle');

  const SyncFrequency(this.interval, this.label);
  final Duration interval;
  final String label;

  bool get isBackgroundEnabled => this != SyncFrequency.manual;
}

/// Uygulamanın tema tercihi. Flutter'ın kendi `ThemeMode`ı yalnızca
/// sistem/açık/koyu bilir; burada Outlook Koyu gibi ekstra, isteğe bağlı
/// temalar da bir seçenek olarak eklenebilsin diye kendi enum'umuz var.
///
/// SIRALAMA ÖNEMLİ: ilk üç değer bilerek Flutter'ın `ThemeMode`ıyla aynı
/// sırada (system, light, dark) — `AppSettingsStore` tercihi `index` olarak
/// sakladığından, önceden kaydedilmiş bir tercih bu sıralama bozulursa yanlış
/// temaya karşılık gelir. Yeni temalar her zaman SONA eklenir.
enum AppThemeMode {
  system('Sistem ayarını izle'),
  light('Açık'),
  dark('Koyu'),
  outlookDark('Outlook Koyu');

  const AppThemeMode(this.label);
  final String label;

  /// `MaterialApp.themeMode` karşılığı — `outlookDark` her zaman koyu
  /// tarafı kullanır (`KaydetApp` bu durumda `theme`/`darkTheme`nin ikisini
  /// de `AppTheme.outlookDark()` yapar, bkz. `app.dart`).
  ThemeMode get flutterThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark || AppThemeMode.outlookDark => ThemeMode.dark,
  };
}

/// Uygulama tercihleri.
class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.dark,
    this.notificationsEnabled = true,
    this.notificationPermissionAsked = false,
    this.syncFrequency = SyncFrequency.push,
    this.confirmBeforeDelete = true,
    this.markSeenDelayMs = 1500,
  });

  final AppThemeMode themeMode;
  final bool notificationsEnabled;

  /// Sistem bildirim izni daha önce bir kez soruldu mu? (bkz.
  /// `SettingsNotifier.requestNotificationPermissionOnce`)
  final bool notificationPermissionAsked;
  final SyncFrequency syncFrequency;
  final bool confirmBeforeDelete;

  /// Mail açıldıktan kaç ms sonra okundu işaretlenir.
  ///
  /// Anında işaretlenirse, yanlış iletiye dokunup hemen geri çıkan kullanıcı
  /// o iletiyi okunmuş bulur.
  final int markSeenDelayMs;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? notificationsEnabled,
    bool? notificationPermissionAsked,
    SyncFrequency? syncFrequency,
    bool? confirmBeforeDelete,
    int? markSeenDelayMs,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        notificationPermissionAsked:
            notificationPermissionAsked ?? this.notificationPermissionAsked,
        syncFrequency: syncFrequency ?? this.syncFrequency,
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
  static const _kPermissionAsked = 'kaydet.notificationPermissionAsked';
  static const _kSync = 'kaydet.syncFrequency';
  static const _kConfirmDelete = 'kaydet.confirmDelete';

  static Future<AppSettingsStore> create() async =>
      AppSettingsStore(await SharedPreferences.getInstance());

  AppSettings read() {
    final themeIndex = _prefs.getInt(_kTheme);
    final syncIndex = _prefs.getInt(_kSync);
    return AppSettings(
      themeMode: themeIndex == null
          ? AppThemeMode.dark
          : AppThemeMode.values[themeIndex.clamp(
              0,
              AppThemeMode.values.length - 1,
            )],
      notificationsEnabled: _prefs.getBool(_kNotifications) ?? true,
      notificationPermissionAsked: _prefs.getBool(_kPermissionAsked) ?? false,
      syncFrequency: syncIndex == null
          ? SyncFrequency.push
          : SyncFrequency
              .values[syncIndex.clamp(0, SyncFrequency.values.length - 1)],
      confirmBeforeDelete: _prefs.getBool(_kConfirmDelete) ?? true,
    );
  }

  Future<void> write(AppSettings settings) async {
    await _prefs.setInt(_kTheme, settings.themeMode.index);
    await _prefs.setBool(_kNotifications, settings.notificationsEnabled);
    await _prefs.setBool(_kPermissionAsked, settings.notificationPermissionAsked);
    await _prefs.setInt(_kSync, settings.syncFrequency.index);
    await _prefs.setBool(_kConfirmDelete, settings.confirmBeforeDelete);
  }
}
