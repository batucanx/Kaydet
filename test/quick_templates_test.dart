import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/quick_templates_store.dart';
import 'package:kaydet/domain/models/quick_template.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late QuickTemplatesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = QuickTemplatesStore(prefs);
  });

  group('QuickTemplatesStore', () {
    test('başlangıçta 5 yerleşik şablon bulunur', () {
      final templates = store.read();
      expect(templates.length, 5);
      expect(templates.every((t) => t.isBuiltIn), isTrue);
      expect(templates.any((t) => t.title.contains('Bilgilerinizi aldım')), isTrue);
      expect(templates.any((t) => t.title.contains('Toplantı Onayı')), isTrue);
    });

    test('yeni özel şablon eklenebilir', () async {
      const custom = QuickTemplate(
        id: 'custom-1',
        title: 'Özel Teklif Yanıtı',
        content: 'Teklifinizi inceledik, onaylıyoruz.',
      );

      await store.save(custom);
      final templates = store.read();

      expect(templates.length, 6);
      expect(templates.first.id, 'custom-1');
      expect(templates.first.title, 'Özel Teklif Yanıtı');
    });

    test('var olan şablon güncellenebilir', () async {
      const custom = QuickTemplate(
        id: 'custom-1',
        title: 'Eski Başlık',
        content: 'Eski içerik',
      );
      await store.save(custom);

      const updated = QuickTemplate(
        id: 'custom-1',
        title: 'Yeni Başlık',
        content: 'Güncel içerik',
      );
      await store.save(updated);

      final templates = store.read();
      expect(templates.length, 6);
      final found = templates.firstWhere((t) => t.id == 'custom-1');
      expect(found.title, 'Yeni Başlık');
      expect(found.content, 'Güncel içerik');
    });

    test('şablon silinebilir', () async {
      const custom = QuickTemplate(
        id: 'custom-delete-me',
        title: 'Silinecek',
        content: 'Sil',
      );
      await store.save(custom);
      expect(store.read().any((t) => t.id == 'custom-delete-me'), isTrue);

      await store.delete('custom-delete-me');
      expect(store.read().any((t) => t.id == 'custom-delete-me'), isFalse);
    });

    test('sıfırlanınca yerleşik şablonlara döner', () async {
      await store.save(
        const QuickTemplate(id: 'temp', title: 'Geçici', content: 'Metin'),
      );
      expect(store.read().length, 6);

      await store.resetToDefaults();
      expect(store.read().length, 5);
      expect(store.read().every((t) => t.isBuiltIn), isTrue);
    });
  });
}
