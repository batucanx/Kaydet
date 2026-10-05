import 'package:shared_preferences/shared_preferences.dart';

/// Bir hesabın ayar eşitlemesinin kalıcı durumu.
class SettingsSyncState {
  const SettingsSyncState({this.baseJson, this.rev = 0});

  /// Son birleştirilen `SettingsData`nın JSON'u — bir sonraki üç yönlü
  /// birleştirmenin ortak atası. `null`: hiç birleştirilmedi.
  final String? baseJson;

  /// Görülen ya da yazılan en yüksek belge sürümü.
  final int rev;
}

/// Ayar eşitleme durumunu saklar. Veritabanı şemasına dokunmamak için
/// SharedPreferences kullanılır (küçük, hesap başına iki değer).
abstract interface class SettingsSyncStateStore {
  Future<SettingsSyncState> read(int accountId);
  Future<void> write(int accountId, SettingsSyncState state);
  Future<void> clear(int accountId);
}

class PrefsSettingsSyncStateStore implements SettingsSyncStateStore {
  const PrefsSettingsSyncStateStore();

  static String _baseKey(int accountId) => 'kaydet.settingsSync.base.$accountId';
  static String _revKey(int accountId) => 'kaydet.settingsSync.rev.$accountId';

  @override
  Future<SettingsSyncState> read(int accountId) async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsSyncState(
      baseJson: prefs.getString(_baseKey(accountId)),
      rev: prefs.getInt(_revKey(accountId)) ?? 0,
    );
  }

  @override
  Future<void> write(int accountId, SettingsSyncState state) async {
    final prefs = await SharedPreferences.getInstance();
    final base = state.baseJson;
    if (base == null) {
      await prefs.remove(_baseKey(accountId));
    } else {
      await prefs.setString(_baseKey(accountId), base);
    }
    await prefs.setInt(_revKey(accountId), state.rev);
  }

  @override
  Future<void> clear(int accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baseKey(accountId));
    await prefs.remove(_revKey(accountId));
  }
}

/// Testler ve SharedPreferences'ın olmadığı ortamlar için.
class MemorySettingsSyncStateStore implements SettingsSyncStateStore {
  final Map<int, SettingsSyncState> _states = {};

  @override
  Future<SettingsSyncState> read(int accountId) async =>
      _states[accountId] ?? const SettingsSyncState();

  @override
  Future<void> write(int accountId, SettingsSyncState state) async =>
      _states[accountId] = state;

  @override
  Future<void> clear(int accountId) async => _states.remove(accountId);
}
