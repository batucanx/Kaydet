import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/share_intake_service.dart';
import 'package:kaydet/domain/models/share_payload.dart';
import 'package:kaydet/domain/use_cases/share_attachment_policy.dart';
import 'package:path/path.dart' as p;

/// Native tarafı taklit eden kanal: gerçek `ShareIntakeService`, sahte
/// `share_inbox` dizini. Dizin gerçek diskte durur; böylece dosya
/// doğrulaması/süpürme gerçek `dart:io` ile sınanır.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ShareIntakeService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory inbox;
  late DateTime now;
  late ShareIntakeService service;
  late List<MethodCall> calls;
  final manifests = <String>[];

  setUp(() {
    inbox = Directory.systemTemp.createTempSync('kaydet_share_inbox_');
    now = DateTime.now().toUtc();
    manifests.clear();
    calls = [];
    service = ShareIntakeService(channel: channel, clock: () => now);

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'takePendingShares':
          return {'root': inbox.path, 'payloads': List<String>.of(manifests)};
        case 'inboxRoot':
          return inbox.path;
        case 'acknowledgeShare':
        case 'discardShare':
          return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    service.dispose();
    if (inbox.existsSync()) inbox.deleteSync(recursive: true);
  });

  /// Native tarafın yazdığı gibi bir paylaşım dizini + manifest oluşturur.
  SharePayload stage({
    required String id,
    Map<String, List<int>> files = const {},
    DateTime? receivedAt,
    bool writeManifestFile = true,
    List<Map<String, Object?>>? declared,
  }) {
    final dir = Directory(p.join(inbox.path, id))..createSync(recursive: true);
    for (final entry in files.entries) {
      File(p.join(dir.path, entry.key)).writeAsBytesSync(entry.value);
    }
    final json = jsonEncode({
      'version': 1,
      'id': id,
      'source': 'android-share',
      'receivedAtMs': (receivedAt ?? now).millisecondsSinceEpoch,
      'files':
          declared ??
          [
            for (final e in files.entries)
              {
                'fileName': e.key,
                'mimeType': 'application/octet-stream',
                'sizeBytes': e.value.length,
              },
          ],
    });
    if (writeManifestFile) {
      File(p.join(dir.path, 'manifest.json')).writeAsStringSync(json);
    }
    manifests.add(json);
    return SharePayload.tryParse(json, root: inbox.path)!;
  }

  const idA = 'aaaaaaaa-0000-4000-8000-000000000001';
  const idB = 'bbbbbbbb-0000-4000-8000-000000000002';
  const idC = 'cccccccc-0000-4000-8000-000000000003';

  group('takePending', () {
    test('en eskiden yeniye sıralar ve yolları root altında kurar', () async {
      stage(
        id: idB,
        files: {
          'b.txt': [1],
        },
        receivedAt: now,
      );
      stage(
        id: idA,
        files: {
          'a.txt': [1],
        },
        receivedAt: now.subtract(const Duration(minutes: 5)),
      );

      final payloads = await service.takePending();

      expect(payloads.map((x) => x.id), [idA, idB]);
      expect(
        payloads.first.files.single.path,
        p.join(inbox.path, idA, 'a.txt'),
      );
    });

    test(
      'durumsuzdur: aynı paylaşımı tüketilene kadar tekrar döndürür',
      () async {
        stage(
          id: idA,
          files: {
            'a.txt': [1],
          },
        );

        expect(await service.takePending(), hasLength(1));
        expect(await service.takePending(), hasLength(1));
      },
    );

    test('bozuk manifesti atlar, sağlam olanı teslim eder', () async {
      manifests.add('{bozuk');
      stage(
        id: idA,
        files: {
          'a.txt': [1],
        },
      );

      expect((await service.takePending()).single.id, idA);
    });

    test(
      '24 saatten eski tüketilmemiş paylaşım silinir, teslim edilmez',
      () async {
        stage(
          id: idA,
          files: {
            'a.txt': [1],
          },
          receivedAt: now.subtract(const Duration(hours: 25)),
        );

        expect(await service.takePending(), isEmpty);
        expect(
          calls.where((c) => c.method == 'discardShare').single.arguments,
          {'id': idA},
        );
      },
    );

    test('native taraf yoksa ya da hata verirse boş liste döner', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await service.takePending(), isEmpty);

      messenger.setMockMethodCallHandler(channel, null);
      expect(await service.takePending(), isEmpty);
    });

    test('acknowledge ve discard kimliği native tarafa iletir', () async {
      await service.acknowledge(idA);
      await service.discard(idB);

      expect(calls.map((c) => c.method), ['acknowledgeShare', 'discardShare']);
      expect(calls.first.arguments, {'id': idA});
      expect(calls.last.arguments, {'id': idB});
    });
  });

  group('changes', () {
    test('dinleyici kurulmadan da veri diskte bekler; kurulduktan sonra native '
        'dürtme akışa düşer', () async {
      stage(
        id: idA,
        files: {
          'a.txt': [1],
        },
      );

      // Dinleyici yokken bile çekme paylaşımı bulur (soğuk başlangıç).
      expect(await service.takePending(), hasLength(1));

      service.listen();
      final nudged = service.changes.first;
      await messenger.handlePlatformMessage(
        ShareIntakeService.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onShareReceived'),
        ),
        (_) {},
      );
      await nudged.timeout(const Duration(seconds: 2));
    });
  });

  group('prepare', () {
    test(
      'sağlam dosyaları gerçek boyutlarıyla ve sırasıyla kabul eder',
      () async {
        final payload = stage(
          id: idA,
          files: {
            'z.jpg': [1, 2, 3],
            'a.pdf': [1, 2],
          },
        );

        final prepared = await service.prepare(payload);

        expect(prepared.files.map((f) => f.fileName), ['z.jpg', 'a.pdf']);
        expect(prepared.files.map((f) => f.sizeBytes), [3, 2]);
        expect(prepared.issues, isEmpty);
      },
    );

    test(
      'olmayan, boş, yasaklı ve çok büyük dosyaları nedeniyle ayıklar',
      () async {
        final payload = stage(
          id: idA,
          files: {
            'iyi.jpg': [1],
            'bos.txt': [],
            'kurulum.exe': [1],
          },
          declared: [
            for (final n in [
              'iyi.jpg',
              'bos.txt',
              'kurulum.exe',
              'kayip.pdf',
              'dev.bin',
            ])
              {'fileName': n, 'mimeType': 'x/y', 'sizeBytes': 1},
          ],
        );
        // Seyrek (sparse) dosya: 25 MB + 1 bayt, diskte yer tutmaz.
        writeSparse(
          p.join(inbox.path, idA, 'dev.bin'),
          ShareAttachmentPolicy.maxFileBytes + 1,
        );

        final prepared = await service.prepare(payload);

        expect(prepared.files.map((f) => f.fileName), ['iyi.jpg']);
        final byName = {for (final i in prepared.issues) i.fileName: i.code};
        expect(byName, {
          'bos.txt': ShareIssueCode.empty,
          'kurulum.exe': ShareIssueCode.blockedType,
          'kayip.pdf': ShareIssueCode.unreadable,
          'dev.bin': ShareIssueCode.tooLarge,
        });
        // Reddedilen dosyalar diskten de silinir.
        expect(File(p.join(inbox.path, idA, 'dev.bin')).existsSync(), isFalse);
        expect(
          File(p.join(inbox.path, idA, 'kurulum.exe')).existsSync(),
          isFalse,
        );
      },
    );

    test('toplam sınırı aşan dosyalar sondan reddedilir', () async {
      final payload = stage(
        id: idA,
        declared: [
          for (final n in ['1.bin', '2.bin', '3.bin'])
            {'fileName': n, 'mimeType': 'x/y', 'sizeBytes': 1},
        ],
      );
      for (final n in ['1.bin', '2.bin', '3.bin']) {
        writeSparse(
          p.join(inbox.path, idA, n),
          ShareAttachmentPolicy.maxFileBytes,
        );
      }

      final prepared = await service.prepare(payload);

      // 25 MB'lık iki dosya 50 MB'a sığar, üçüncüsü toplamı aşar.
      expect(prepared.files.map((f) => f.fileName), ['1.bin', '2.bin']);
      expect(prepared.issues.single.fileName, '3.bin');
      expect(prepared.issues.single.code, ShareIssueCode.tooLarge);
    });

    test('sembolik bağı düz dosya saymaz', () async {
      final target = File(p.join(inbox.path, 'hedef.txt'))
        ..writeAsStringSync('gizli');
      final payload = stage(
        id: idA,
        declared: [
          {'fileName': 'link.txt', 'mimeType': 'text/plain', 'sizeBytes': 5},
        ],
      );
      try {
        Link(p.join(inbox.path, idA, 'link.txt')).createSync(target.path);
      } on FileSystemException {
        // Windows'ta ayrıcalık gerekebilir; bu durumda sınanamaz.
        return;
      }

      final prepared = await service.prepare(payload);

      expect(prepared.files, isEmpty);
      expect(prepared.issues.single.code, ShareIssueCode.unreadable);
    });
  });

  group('sweep', () {
    Directory dirOf(String id) => Directory(p.join(inbox.path, id));

    /// Dizindeki tüm dosyaların (manifest dahil) yazılma zamanını [by] kadar
    /// geriye alır — `Directory` zaman damgası ayarlanamadığı için süpürücü de
    /// dosya zamanlarına bakar.
    void age(String id, Duration by) {
      for (final file in dirOf(id).listSync().whereType<File>()) {
        file.setLastModifiedSync(now.subtract(by));
      }
    }

    test('taslağa bağlı dizine dokunmaz, sahipsiz eskiyi siler', () async {
      stage(
        id: idA,
        files: {
          'a.jpg': [1],
        },
        writeManifestFile: false,
      );
      stage(
        id: idB,
        files: {
          'b.jpg': [1],
        },
        writeManifestFile: false,
      );
      age(idA, const Duration(days: 3));
      age(idB, const Duration(days: 3));

      final removed = await service.sweep(
        referencedPaths: {p.join(inbox.path, idA, 'a.jpg')},
      );

      expect(removed, 1);
      expect(dirOf(idA).existsSync(), isTrue, reason: 'taslak eki korunmalı');
      expect(dirOf(idB).existsSync(), isFalse);
    });

    test('taze (24 saat dolmamış) dizin, sahipsiz olsa bile korunur', () async {
      stage(
        id: idA,
        files: {
          'a.jpg': [1],
        },
        writeManifestFile: false,
      );
      age(idA, const Duration(hours: 2));

      expect(await service.sweep(referencedPaths: {}), 0);
      expect(dirOf(idA).existsSync(), isTrue);
    });

    test(
      'tüketilmemiş (manifestli) paylaşıma süre dolana kadar dokunmaz',
      () async {
        stage(
          id: idA,
          files: {
            'a.jpg': [1],
          },
        );
        stage(
          id: idB,
          files: {
            'b.jpg': [1],
          },
        );
        age(idA, const Duration(hours: 30)); // süresi dolmuş bekleyen
        age(idB, const Duration(hours: 3)); // hâlâ taze bekleyen

        expect(await service.sweep(referencedPaths: {}), 1);
        expect(dirOf(idA).existsSync(), isFalse);
        expect(dirOf(idB).existsSync(), isTrue);
      },
    );

    test('tanınmayan dizin adlarını silmez', () async {
      Directory(p.join(inbox.path, 'benim_klasorum')).createSync();
      stage(
        id: idC,
        files: {
          'c.jpg': [1],
        },
        writeManifestFile: false,
      );
      age(idC, const Duration(days: 9));

      await service.sweep(referencedPaths: {});

      expect(
        Directory(p.join(inbox.path, 'benim_klasorum')).existsSync(),
        isTrue,
      );
      expect(dirOf(idC).existsSync(), isFalse);
    });

    test('Windows/POSIX ayırıcı farkı referansı gizlemez', () async {
      stage(
        id: idA,
        files: {
          'a.jpg': [1],
        },
        writeManifestFile: false,
      );
      age(idA, const Duration(days: 3));

      // DB'deki yol ters bölülü de gelebilir (Windows) — eşleşme bozulmamalı.
      final backslashed = p.join(inbox.path, idA, 'a.jpg').replaceAll('/', r'');
      expect(await service.sweep(referencedPaths: {backslashed}), 0);
      expect(dirOf(idA).existsSync(), isTrue);
    });
  });
}

/// Diskte yer tutmayan (seyrek) [size] baytlık dosya.
void writeSparse(String path, int size) {
  final raf = File(path).openSync(mode: FileMode.write);
  try {
    raf
      ..setPositionSync(size - 1)
      ..writeByteSync(1);
  } finally {
    raf.closeSync();
  }
}
