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

/// Mail satırında sağa/sola kaydırmayla atanabilen eylemler.
///
/// Yalnızca uygulamanın gerçekten desteklediği tek dokunuşluk eylemler
/// buradadır. Klasörde/duruma göre nihai eylem `SwipeActionResolver` ile
/// belirlenir (ör. Arşiv'de "Arşivle" → "Gelen Kutusuna taşı").
///
/// SIRALAMA ÖNEMLİ: tercih `index` olarak saklanır; yeni değerler SONA eklenir.
enum SwipeAction {
  archive('Arşivle'),
  delete('Sil'),
  toggleRead('Okundu / okunmadı'),
  readAndArchive('Oku ve arşivle'),
  pin('Sabitle'),
  none('Yok'),

  /// Yalnızca varsayılan "ilk kurulum" yer tutucusu: kaydırınca Çekme
  /// seçenekleri açılır. Seçim listesinde yoktur.
  configure('Ayarla');

  const SwipeAction(this.label);
  final String label;
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
    this.showBrandLogos = true,
    this.syncFrequency = SyncFrequency.push,
    this.confirmBeforeDelete = true,
    this.markSeenDelayMs = 1500,
    this.swipeRight = SwipeAction.configure,
    this.swipeLeft = SwipeAction.delete,
  });

  final AppThemeMode themeMode;
  final bool notificationsEnabled;

  /// Sistem bildirim izni daha önce bir kez soruldu mu? (bkz.
  /// `SettingsNotifier.requestNotificationPermissionOnce`)
  final bool notificationPermissionAsked;

  /// Gönderen avatarlarında marka logosu (bkz. `BrandAvatar`) gösterilsin mi?
  /// Açıkken gönderenlerin ALAN ADLARI Google'ın favicon servisine iletilir;
  /// kapalıyken hiçbir ağ isteği yapılmaz, renkli baş harf gösterilir.
  final bool showBrandLogos;
  final SyncFrequency syncFrequency;
  final bool confirmBeforeDelete;

  /// Mail açıldıktan kaç ms sonra okundu işaretlenir.
  ///
  /// Anında işaretlenirse, yanlış iletiye dokunup hemen geri çıkan kullanıcı
  /// o iletiyi okunmuş bulur.
  final int markSeenDelayMs;

  /// Sağa ve sola kaydırma eylemleri — birbirinden bağımsız, genel varsayılan;
  /// klasöre göre uyarlanması `SwipeActionResolver`ın işidir.
  final SwipeAction swipeRight;
  final SwipeAction swipeLeft;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? notificationsEnabled,
    bool? notificationPermissionAsked,
    bool? showBrandLogos,
    SyncFrequency? syncFrequency,
    bool? confirmBeforeDelete,
    int? markSeenDelayMs,
    SwipeAction? swipeRight,
    SwipeAction? swipeLeft,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        notificationPermissionAsked:
            notificationPermissionAsked ?? this.notificationPermissionAsked,
        showBrandLogos: showBrandLogos ?? this.showBrandLogos,
        syncFrequency: syncFrequency ?? this.syncFrequency,
        confirmBeforeDelete: confirmBeforeDelete ?? this.confirmBeforeDelete,
        markSeenDelayMs: markSeenDelayMs ?? this.markSeenDelayMs,
        swipeRight: swipeRight ?? this.swipeRight,
        swipeLeft: swipeLeft ?? this.swipeLeft,
      );
}

/// Tercihlerin kalıcı saklanması.
class AppSettingsStore {
  AppSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kTheme = 'kaydet.themeMode';
  static const _kNotifications = 'kaydet.notifications';
  static const _kPermissionAsked = 'kaydet.notificationPermissionAsked';
  static const _kBrandLogos = 'kaydet.showBrandLogos';
  static const _kSync = 'kaydet.syncFrequency';
  static const _kConfirmDelete = 'kaydet.confirmDelete';
  static const _kSwipeRight = 'kaydet.swipeRight';
  static const _kSwipeLeft = 'kaydet.swipeLeft';

  static Future<AppSettingsStore> create() async =>
      AppSettingsStore(await SharedPreferences.getInstance());

  /// `RemotePushSync`'in kendi kayıt anahtarlarını (token, hesap parmak
  /// izleri) tuttuğu ham depo — bkz. `SharedPrefsRegistrationStore`.
  SharedPreferences get preferences => _prefs;

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
      showBrandLogos: _prefs.getBool(_kBrandLogos) ?? true,
      syncFrequency: syncIndex == null
          ? SyncFrequency.push
          : SyncFrequency
              .values[syncIndex.clamp(0, SyncFrequency.values.length - 1)],
      confirmBeforeDelete: _prefs.getBool(_kConfirmDelete) ?? true,
      swipeRight: _readSwipe(_kSwipeRight, SwipeAction.configure),
      swipeLeft: _readSwipe(_kSwipeLeft, SwipeAction.delete),
    );
  }

  SwipeAction _readSwipe(String key, SwipeAction fallback) {
    final index = _prefs.getInt(key);
    if (index == null || index < 0 || index >= SwipeAction.values.length) {
      return fallback;
    }
    return SwipeAction.values[index];
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
    await _prefs.setBool(_kBrandLogos, settings.showBrandLogos);
    await _prefs.setInt(_kSync, settings.syncFrequency.index);
    await _prefs.setBool(_kConfirmDelete, settings.confirmBeforeDelete);
    await _prefs.setInt(_kSwipeRight, settings.swipeRight.index);
    await _prefs.setInt(_kSwipeLeft, settings.swipeLeft.index);
  }
}
