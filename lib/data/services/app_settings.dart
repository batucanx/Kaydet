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

/// Uygulamanın tema tercihi. Flutter'ın kendi `ThemeMode`ıyla birebir
/// eşlenir (system/light/dark); ayrı bir enum olmasının nedeni yalnızca
/// Türkçe etiket (`label`) taşıması.
///
/// SIRALAMA ÖNEMLİ: `AppSettingsStore` tercihi `index` olarak sakladığından,
/// sıralama bozulursa önceden kaydedilmiş bir tercih yanlış temaya karşılık
/// gelir. Yeni değerler her zaman SONA eklenir.
enum AppThemeMode {
  system('Sistem ayarını izle'),
  light('Açık'),
  dark('Koyu');

  const AppThemeMode(this.label);
  final String label;

  ThemeMode get flutterThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

/// Uygulama tercihleri.
class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.dark,
    this.notificationsEnabled = true,
    this.notificationPermissionAsked = false,
    this.remotePushEnabled = false,
    this.syncFrequency = SyncFrequency.push,
    this.confirmBeforeDelete = true,
    this.markSeenDelayMs = 1500,
  });

  final AppThemeMode themeMode;
  final bool notificationsEnabled;

  /// Sistem bildirim izni daha önce bir kez soruldu mu? (bkz.
  /// `SettingsNotifier.requestNotificationPermissionOnce`)
  final bool notificationPermissionAsked;

  /// Anlık bildirim için hesap bilgileri (şifre dahil) push sunucusuna
  /// gönderilsin mi? Kullanıcı açıkça onaylamadıkça KAPALI kalır.
  final bool remotePushEnabled;
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
    bool? remotePushEnabled,
    SyncFrequency? syncFrequency,
    bool? confirmBeforeDelete,
    int? markSeenDelayMs,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        notificationPermissionAsked:
            notificationPermissionAsked ?? this.notificationPermissionAsked,
        remotePushEnabled: remotePushEnabled ?? this.remotePushEnabled,
        syncFrequency: syncFrequency ?? this.syncFrequency,
        confirmBeforeDelete: confirmBeforeDelete ?? this.confirmBeforeDelete,
        markSeenDelayMs: markSeenDelayMs ?? this.markSeenDelayMs,
      );
}

/// Tercihlerin kalıcı saklanması.
class AppSettingsStore {
  AppSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  /// Ayar dışı küçük kalıcı durumlar için (bkz. `SharedPrefsRegistrationStore`).
  SharedPreferences get preferences => _prefs;

  static const _kTheme = 'kaydet.themeMode';
  static const _kNotifications = 'kaydet.notifications';
  static const _kPermissionAsked = 'kaydet.notificationPermissionAsked';
  static const _kRemotePush = 'kaydet.remotePushEnabled';
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
      remotePushEnabled: _prefs.getBool(_kRemotePush) ?? false,
      syncFrequency: syncIndex == null
          ? SyncFrequency.push
          : SyncFrequency
              .values[syncIndex.clamp(0, SyncFrequency.values.length - 1)],
      confirmBeforeDelete: _prefs.getBool(_kConfirmDelete) ?? true,
    );
  }

  static const _kCollapsedFolders = 'kaydet.collapsedFolders.';

  /// Hesap bazında daraltılmış (alt klasörleri gizlenmiş) klasör id'lerini okur.
  Set<int> readCollapsedFolders(int accountId) {
    final list = _prefs.getStringList('$_kCollapsedFolders$accountId');
    if (list == null) return const {};
    return list.map(int.tryParse).whereType<int>().toSet();
  }

  /// Hesap bazında daraltılmış klasör id'lerini kalıcı kaydeder.
  Future<void> writeCollapsedFolders(int accountId, Set<int> ids) async {
    await _prefs.setStringList(
      '$_kCollapsedFolders$accountId',
      ids.map((id) => id.toString()).toList(),
    );
  }

  Future<void> write(AppSettings settings) async {
    await _prefs.setInt(_kTheme, settings.themeMode.index);
    await _prefs.setBool(_kNotifications, settings.notificationsEnabled);
    await _prefs.setBool(_kPermissionAsked, settings.notificationPermissionAsked);
    await _prefs.setBool(_kRemotePush, settings.remotePushEnabled);
    await _prefs.setInt(_kSync, settings.syncFrequency.index);
    await _prefs.setBool(_kConfirmDelete, settings.confirmBeforeDelete);
  }
}
