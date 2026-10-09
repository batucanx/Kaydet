import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/quick_template.dart';

/// Hazır yanıt ve şablonların SharedPreferences üzerinde saklanmasını yönetir.
/// Test ortamı veya SharedPreferences sağlanmadığında otomatik olarak
/// bellek üzerinde çalışır.
class QuickTemplatesStore {
  QuickTemplatesStore([this._prefs]);

  final SharedPreferences? _prefs;
  static const _key = 'kaydet.quickTemplates';

  final List<QuickTemplate> _memoryTemplates =
      List.of(builtInTemplates);

  static const List<QuickTemplate> builtInTemplates = [
    QuickTemplate(
      id: 'builtin-1',
      title: 'Bilgilerinizi aldım',
      content:
          'Merhaba,\n\nİletinizi aldım. Konuyu detaylıca inceleyip en kısa sürede tarafınıza geri dönüş sağlayacağım.\n\nİyi çalışmalar dilerim.',
      isBuiltIn: true,
    ),
    QuickTemplate(
      id: 'builtin-2',
      title: 'Toplantı Onayı',
      content:
          'Merhaba,\n\nToplantı davetiniz için teşekkür ederim. Belirtilen gün ve saatte katılım sağlayacağım.\n\nGörüşmek üzere.',
      isBuiltIn: true,
    ),
    QuickTemplate(
      id: 'builtin-3',
      title: 'Fatura ve Belgeler Ektedir',
      content:
          'Merhaba,\n\nTalep ettiğiniz fatura ve ilgili belgeler ekte bilgilerinize sunulmuştur. Herhangi bir sorunuz olursa lütfen iletiniz.\n\nİyi günler dilerim.',
      isBuiltIn: true,
    ),
    QuickTemplate(
      id: 'builtin-4',
      title: 'Gecikme Bilgilendirmesi',
      content:
          'Merhaba,\n\nYoğunluk sebebiyle geri dönüşümde yaşanan gecikme için özür dilerim. Konunuz üzerinde çalışıyorum, güncel durumu gün içerisinde paylaşacağım.\n\nAnlayışınız için teşekkür ederim.',
      isBuiltIn: true,
    ),
    QuickTemplate(
      id: 'builtin-5',
      title: 'Teşekkürler & İyi Çalışmalar',
      content:
          'Bilgilendirme ve desteğiniz için çok teşekkür ederim.\n\nİyi çalışmalar dilerim.',
      isBuiltIn: true,
    ),
  ];

  static Future<QuickTemplatesStore> create() async =>
      QuickTemplatesStore(await SharedPreferences.getInstance());

  /// Şablonlar hiç kaydedilmedi mi (kullanıcı ve eşitleme dokunmadı)? O zaman [read] yerleşik
  /// varsayılanları döner; bunlar kullanıcının seçimi değil, yalnızca başlangıç değeridir.
  bool get isPristine {
    final prefs = _prefs;
    if (prefs == null) return _memoryPristine;
    return prefs.getStringList(_key) == null;
  }

  bool _memoryPristine = true;

  /// Kayıtlı şablonları okur. Hiç şablon kaydedilmemişse yerleşik varsayılanları döner.
  List<QuickTemplate> read() {
    final prefs = _prefs;
    if (prefs == null) {
      return List.unmodifiable(_memoryTemplates);
    }
    final raw = prefs.getStringList(_key);
    // Hiç kaydedilmemişse varsayılanlar; kullanıcı hepsini sildiyse BOŞ kalır (aksi hâlde silinen
    // şablonlar geri gelir ve web ile eşitlenen silme geri alınırdı).
    if (raw == null) {
      return List.of(builtInTemplates);
    }
    try {
      return raw.map((item) {
        final decoded = jsonDecode(item) as Map<String, dynamic>;
        return QuickTemplate.fromJson(decoded);
      }).toList();
    } on Object {
      return List.of(builtInTemplates);
    }
  }

  /// Yeni şablon ekler ya da var olanı günceller.
  Future<void> save(QuickTemplate template) async {
    final current = List<QuickTemplate>.from(read());
    final index = current.indexWhere((t) => t.id == template.id);
    if (index >= 0) {
      current[index] = template;
    } else {
      current.insert(0, template);
    }
    await _persist(current);
  }

  /// Tüm şablon listesini değiştirir (web ile eşitleme sonucu).
  Future<void> replaceAll(List<QuickTemplate> templates) =>
      _persist(List.of(templates));

  /// Belirtilen şablonu siler.
  Future<void> delete(String id) async {
    final current = read().where((t) => t.id != id).toList();
    await _persist(current);
  }

  /// Tüm şablonları varsayılana sıfırlar.
  Future<void> resetToDefaults() async {
    final prefs = _prefs;
    if (prefs != null) {
      await prefs.remove(_key);
    } else {
      _memoryTemplates.clear();
      _memoryTemplates.addAll(builtInTemplates);
      _memoryPristine = true;
    }
  }

  Future<void> _persist(List<QuickTemplate> templates) async {
    final prefs = _prefs;
    if (prefs != null) {
      final encoded = templates.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_key, encoded);
    } else {
      _memoryTemplates.clear();
      _memoryTemplates.addAll(templates);
      _memoryPristine = false;
    }
  }
}

/// Şablonları yöneten Riverpod Notifier
class QuickTemplatesNotifier extends Notifier<List<QuickTemplate>> {
  @override
  List<QuickTemplate> build() => ref.watch(quickTemplatesStoreProvider).read();

  Future<void> addOrUpdate(QuickTemplate template) async {
    await ref.read(quickTemplatesStoreProvider).save(template);
    state = ref.read(quickTemplatesStoreProvider).read();
  }

  Future<void> remove(String id) async {
    await ref.read(quickTemplatesStoreProvider).delete(id);
    state = ref.read(quickTemplatesStoreProvider).read();
  }

  /// Depo dışarıdan (ayar eşitlemesi) değişti: durumu yeniden oku.
  void refresh() => state = ref.read(quickTemplatesStoreProvider).read();

  Future<void> reset() async {
    await ref.read(quickTemplatesStoreProvider).resetToDefaults();
    state = ref.read(quickTemplatesStoreProvider).read();
  }
}

final quickTemplatesStoreProvider = Provider<QuickTemplatesStore>((ref) {
  return QuickTemplatesStore();
});

final quickTemplatesProvider =
    NotifierProvider<QuickTemplatesNotifier, List<QuickTemplate>>(
  QuickTemplatesNotifier.new,
);
