import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/attachment_files.dart';
import 'package:kaydet/data/services/outgoing_attachment_store.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AttachmentFiles.safeFileName', () {
    test('sıradan adı olduğu gibi bırakır', () {
      expect(AttachmentFiles.safeFileName('rapor.pdf'), 'rapor.pdf');
      expect(AttachmentFiles.safeFileName('Çözüm Önerisi.docx'), 'Çözüm Önerisi.docx');
    });

    test('yol ayırıcıları ve geçersiz karakterleri değiştirir', () {
      final name = AttachmentFiles.safeFileName('../../etc/passwd');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(r'\')));
      expect(AttachmentFiles.safeFileName('a<b>c:d|e?.txt'), 'a_b_c_d_e_.txt');
    });

    test('nokta ve boşluktan ibaret adlar güvenli bir ada döner', () {
      expect(AttachmentFiles.safeFileName('..'), 'dosya');
      expect(AttachmentFiles.safeFileName('.'), 'dosya');
      expect(AttachmentFiles.safeFileName('   '), 'dosya');
      expect(AttachmentFiles.safeFileName(''), 'dosya');
    });

    test('sondaki nokta ve boşluk atılır', () {
      expect(AttachmentFiles.safeFileName('rapor. '), 'rapor');
    });

    test('çok uzun ad kısaltılır, uzantı korunur', () {
      final name = AttachmentFiles.safeFileName('${'a' * 400}.pdf');
      expect(name.runes.length, lessThanOrEqualTo(150));
      expect(name.endsWith('.pdf'), isTrue);
    });
  });

  group('AttachmentFiles.isManaged', () {
    test('yalnızca `ekler` dizininin altındaki yollar yönetilir', () {
      expect(AttachmentFiles.isManaged('/veri/ekler/5/9/a.pdf'), isTrue);
      expect(AttachmentFiles.isManaged('/veri/ekler/5/a.pdf'), isTrue);
      expect(AttachmentFiles.isManaged('/veri/baska/a.pdf'), isFalse);
      // `ekler` dizininin kendisi ya da onu içeren ama üstündeki yollar değil.
      expect(AttachmentFiles.isManaged('/veri/ekler'), isFalse);
    });
  });

  group('AttachmentFiles.deleteAll', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('kaydet_ek_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('dosyayı siler ve boşalan ara klasörleri temizler', () async {
      final keep = File(p.join(temp.path, 'ekler', '1', '1', 'kalsin.pdf'))
        ..createSync(recursive: true);
      final remove = File(p.join(temp.path, 'ekler', '2', '5', 'gitsin.pdf'))
        ..createSync(recursive: true);

      await AttachmentFiles.deleteAll([remove.path]);

      expect(remove.existsSync(), isFalse);
      expect(Directory(p.join(temp.path, 'ekler', '2')).existsSync(), isFalse);
      expect(keep.existsSync(), isTrue);
      expect(Directory(p.join(temp.path, 'ekler')).existsSync(), isTrue);
    });

    test('dolu bir klasörü silmez', () async {
      final a = File(p.join(temp.path, 'ekler', '3', '1', 'a.pdf'))
        ..createSync(recursive: true);
      final b = File(p.join(temp.path, 'ekler', '3', '2', 'b.pdf'))
        ..createSync(recursive: true);

      await AttachmentFiles.deleteAll([a.path]);

      expect(b.existsSync(), isTrue);
      expect(Directory(p.join(temp.path, 'ekler', '3')).existsSync(), isTrue);
    });

    test('olmayan dosya ve `ekler` dışındaki yol hata vermez, dokunulmaz', () async {
      final outside = File(p.join(temp.path, 'baska', 'x.txt'))
        ..createSync(recursive: true);

      await AttachmentFiles.deleteAll([
        p.join(temp.path, 'ekler', '9', '9', 'yok.pdf'),
        outside.path,
      ]);

      expect(outside.existsSync(), isTrue);
    });
  });

  group('OutgoingAttachmentStore', () {
    late Directory temp;
    late Directory root;
    late OutgoingAttachmentStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('kaydet_giden_');
      root = Directory(p.join(temp.path, 'giden_ekler'));
      store = OutgoingAttachmentStore(rootProvider: () async => root);
    });
    tearDown(() => temp.deleteSync(recursive: true));

    File source(String name, [String content = 'içerik']) =>
        File(p.join(temp.path, 'gecici', name))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    test('dosyayı kalıcı klasöre kopyalar, kaynağı bırakır', () async {
      final original = source('sunum.pptx', 'slaytlar');

      final stored = await store.persist(original.path);

      expect(p.isWithin(root.path, stored), isTrue);
      expect(p.basename(stored), 'sunum.pptx');
      expect(File(stored).readAsStringSync(), 'slaytlar');
      expect(original.existsSync(), isTrue);
    });

    test('zaten kalıcı klasördeki dosya aynen döner', () async {
      final stored = await store.persist(source('a.txt').path);

      expect(await store.persist(stored), stored);
    });

    test('aynı adlı iki dosya birbirinin üstüne yazılmaz', () async {
      final first = await store.persist(source('image.png', 'bir').path);
      // Yeni bir kaynak (aynı ad, farklı içerik).
      final second = await store.persist(
        (File(p.join(temp.path, 'baska', 'image.png'))
              ..createSync(recursive: true)
              ..writeAsStringSync('iki'))
            .path,
      );

      expect(first, isNot(second));
      expect(File(first).readAsStringSync(), 'bir');
      expect(File(second).readAsStringSync(), 'iki');
    });

    test('kaynak yoksa hata verir ve yarım kopya bırakmaz', () async {
      await expectLater(
        store.persist(p.join(temp.path, 'yok.txt')),
        throwsA(isA<FileSystemException>()),
      );

      expect(root.listSync(), isEmpty);
    });

    test('süpürme: etkin olmayan ve süresi dolmuş kopyalar silinir', () async {
      final stale = await store.persist(source('eski.pdf').path);
      final active = await store.persist(source('etkin.pdf').path);
      final future = DateTime.now().add(const Duration(days: 2));

      final removed = await store.sweep(activePaths: {active}, now: future);

      expect(removed, 1);
      expect(File(stale).existsSync(), isFalse);
      expect(File(active).existsSync(), isTrue);
    });

    test('süpürme: yeni kopyalar (henüz taslağa yazılmamış) korunur', () async {
      final fresh = await store.persist(source('yeni.pdf').path);

      final removed = await store.sweep(activePaths: const {});

      expect(removed, 0);
      expect(File(fresh).existsSync(), isTrue);
    });

    test('süpürme: klasör hiç yoksa hata vermez', () async {
      expect(await store.sweep(activePaths: const {}), 0);
    });
  });
}
