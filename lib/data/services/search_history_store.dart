import 'package:shared_preferences/shared_preferences.dart';

/// Arama geçmişinin kalıcı saklanması — tüm hesaplar için ortak (bkz.
/// arama ekranı tasarım kararı).
class SearchHistoryStore {
  SearchHistoryStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'kaydet.searchHistory';
  static const int maxEntries = 10;

  static Future<SearchHistoryStore> create() async =>
      SearchHistoryStore(await SharedPreferences.getInstance());

  /// En son aranan en üstte.
  List<String> read() => _prefs.getStringList(_key) ?? const [];

  /// Terimi geçmişin başına ekler; zaten varsa önce kaldırılıp tekrar
  /// başa eklenir (yinelenen girdi yerine en güncel sırada tutulur).
  Future<void> add(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return;
    final current = read()
        .where((t) => t.toLowerCase() != trimmed.toLowerCase())
        .toList();
    current.insert(0, trimmed);
    if (current.length > maxEntries) {
      current.removeRange(maxEntries, current.length);
    }
    await _prefs.setStringList(_key, current);
  }

  Future<void> remove(String term) async {
    final current = read().where((t) => t != term).toList();
    await _prefs.setStringList(_key, current);
  }

  Future<void> clear() => _prefs.remove(_key);
}
