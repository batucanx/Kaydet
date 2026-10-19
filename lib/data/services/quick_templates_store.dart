import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart' show activeAccountProvider;
import '../../domain/models/quick_template.dart';

/// Hazır yanıt ve şablonların SharedPreferences üzerinde saklanmasını yönetir.
/// Test ortamı veya SharedPreferences sağlanmadığında otomatik olarak
/// bellek üzerinde çalışır.
///
/// Şablonlar HESABA özgüdür (web'deki gibi): [forAccount] hesabın e-postasına bağlı bir görünüm
/// döner ve her hesap kendi anahtarında saklanır. Anahtar hesabın e-postasıdır, veritabanı kimliği
/// değil: çıkış yapmak şablonlara dokunmaz, aynı adresle yeniden giriş şablonları geri bulur.
/// [forAccount] kullanılmamış (sahipsiz) örnek eski, cihaz geneli tek anahtarı kullanır.
class QuickTemplatesStore {
  QuickTemplatesStore([this._prefs]) : _owner = null, _memory = _Memory();

  QuickTemplatesStore._(this._prefs, this._owner, this._memory);

  final SharedPreferences? _prefs;

  /// Küçük harfli hesap e-postası; `null`: eski cihaz geneli anahtar.
  final String? _owner;
  final _Memory _memory;

  static const _legacyKey = 'kaydet.quickTemplates';
  static const _keyPrefix = 'kaydet.quickTemplates.';

  String get _key => _owner == null ? _legacyKey : '$_keyPrefix$_owner';

  /// [email] hesabının şablonlarına bakan görünüm (aynı depolama, ayrı anahtar).
  QuickTemplatesStore forAccount(String email) =>
      QuickTemplatesStore._(_prefs, email.trim().toLowerCase(), _memory);

  /// Eski sürümde cihaz geneli tek anahtarda kalan şablonları ilk isteyen hesaba taşır ve eski anahtarı
  /// siler; sonraki hesaplar varsayılanlarla başlar. Hesaba özgü kaydı zaten olan hesaba dokunmaz.
  /// Bir şey taşındıysa `true`.
  Future<bool> claimLegacy() async {
    final prefs = _prefs;
    if (prefs == null || _owner == null) return false;
    final legacy = prefs.getStringList(_legacyKey);
    if (legacy == null) return false;
    if (prefs.getStringList(_key) == null) {
      await prefs.setStringList(_key, legacy);
    }
    await prefs.remove(_legacyKey);
    return true;
  }

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
    if (prefs == null) return !_memory.touched.contains(_owner);
    return prefs.getStringList(_key) == null;
  }

  /// Kayıtlı şablonları okur. Hiç şablon kaydedilmemişse yerleşik varsayılanları döner.
  List<QuickTemplate> read() {
    final prefs = _prefs;
    if (prefs == null) {
      return List.unmodifiable(_memory.templates[_owner] ?? builtInTemplates);
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
      _memory.templates.remove(_owner);
      _memory.touched.remove(_owner);
    }
  }

  Future<void> _persist(List<QuickTemplate> templates) async {
    final prefs = _prefs;
    if (prefs != null) {
      final encoded = templates.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_key, encoded);
    } else {
      _memory.templates[_owner] = List.of(templates);
      _memory.touched.add(_owner);
    }
  }
}

/// SharedPreferences olmayan ortamlar için sahip (e-posta) başına bellek deposu.
class _Memory {
  final Map<String?, List<QuickTemplate>> templates = {};
  final Set<String?> touched = {};
}

/// Şablonları yöneten Riverpod Notifier
class QuickTemplatesNotifier extends Notifier<List<QuickTemplate>> {
  QuickTemplatesStore get _store => ref.read(accountTemplatesStoreProvider);

  @override
  List<QuickTemplate> build() {
    final store = ref.watch(accountTemplatesStoreProvider);
    // Eski cihaz geneli şablonlar ilk açılan hesaba taşınır; sonra liste yenilenir.
    unawaited(
      store.claimLegacy().then((moved) {
        if (moved && ref.mounted) state = _store.read();
      }),
    );
    return store.read();
  }

  Future<void> addOrUpdate(QuickTemplate template) async {
    await _store.save(template);
    state = _store.read();
  }

  Future<void> remove(String id) async {
    await _store.delete(id);
    state = _store.read();
  }

  /// Depo dışarıdan (ayar eşitlemesi) değişti: durumu yeniden oku.
  void refresh() => state = _store.read();

  Future<void> reset() async {
    await _store.resetToDefaults();
    state = _store.read();
  }
}

/// Cihazdaki ham depo (hesaplardan bağımsız); `main()` gerçek örnekle geçersiz kılar.
final quickTemplatesStoreProvider = Provider<QuickTemplatesStore>((ref) {
  return QuickTemplatesStore();
});

/// Etkin hesabın şablonları. Hesap değişince başka bir anahtara geçer; etkin hesap yokken
/// (giriş ekranı) sahipsiz depo kullanılır ve yazma bir hesabın verisine karışmaz.
final accountTemplatesStoreProvider = Provider<QuickTemplatesStore>((ref) {
  final base = ref.watch(quickTemplatesStoreProvider);
  final email = ref.watch(activeAccountProvider.select((a) => a.value?.email));
  return email == null ? base : base.forAccount(email);
});

final quickTemplatesProvider =
    NotifierProvider<QuickTemplatesNotifier, List<QuickTemplate>>(
  QuickTemplatesNotifier.new,
);
