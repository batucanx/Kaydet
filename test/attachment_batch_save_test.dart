import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/device_downloads.dart';
import 'package:kaydet/ui/core/actions/attachment_batch_actions.dart';

AttachmentRow row(int id, String name, {String mime = 'application/pdf'}) =>
    AttachmentRow(
      id: id,
      messageId: 1,
      partId: '$id',
      fileName: name,
      mimeType: mime,
      sizeBytes: 1000 * id,
      isInline: false,
      isOutgoing: false,
    );

/// Gerçek platform kanalı yerine, çağrıları kaydeden ve sonucu betikleyen sahte.
class FakeDownloads extends DeviceDownloads {
  FakeDownloads({
    this.direct = true,
    List<DeviceSaveOutcome> outcomes = const [],
  }) : _outcomes = List.of(outcomes);

  final bool direct;
  final List<DeviceSaveOutcome> _outcomes;
  final List<String> savedNames = [];
  final List<String> mimes = [];
  final List<List<SavedDeviceFile>> notified = [];

  @override
  bool get canSaveDirectly => direct;

  @override
  Future<DeviceSaveResult> save({
    required String sourcePath,
    required String fileName,
    String mimeType = '',
  }) async {
    savedNames.add(fileName);
    mimes.add(mimeType);
    final outcome = _outcomes.isEmpty
        ? DeviceSaveOutcome.saved
        : _outcomes.removeAt(0);
    return DeviceSaveResult(
      outcome,
      file: outcome == DeviceSaveOutcome.saved
          ? SavedDeviceFile(
              uri: 'content://media/downloads/${savedNames.length}',
              name: fileName,
              mimeType: mimeType,
            )
          : null,
    );
  }

  @override
  Future<void> notifySaved(List<SavedDeviceFile> files) async {
    notified.add(files);
  }
}

Future<Result<String>> resolveAll(AttachmentRow a) async =>
    Result.ok('/data/ekler/1/${a.id}/${a.fileName}');

void main() {
  final three = [row(1, 'a.pdf'), row(2, 'b.xml'), row(3, 'c.png')];

  group('Android 10+ doğrudan klasör', () {
    test(
      'hepsi sırayla indirilir ve kaydedilir; ilerleme bildirilir',
      () async {
        final downloads = FakeDownloads();
        final progress = <String>[];
        final report = await saveAttachmentsToDevice(
          attachments: three,
          resolvePath: resolveAll,
          downloads: downloads,
          onProgress: (d, t) => progress.add('$d/$t'),
        );
        expect(downloads.savedNames, ['a.pdf', 'b.xml', 'c.png']);
        expect(downloads.mimes.first, 'application/pdf');
        expect(progress, ['0/3', '1/3', '2/3', '3/3']);
        expect(report.saved, 3);
        expect(report.failed, 0);
        expect(report.mode, BatchSaveMode.folder);
        expect(
          report.message,
          '3 ek İndirilenler/Kaydet klasörüne kaydedildi.',
        );
      },
    );

    test('bir ek indirilemezse diğerleri yine kaydedilir', () async {
      final downloads = FakeDownloads();
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: (a) async => a.id == 2
            ? const Result.err(ConnectionFailure())
            : Result.ok('/x/${a.fileName}'),
        downloads: downloads,
      );
      expect(downloads.savedNames, ['a.pdf', 'c.png']);
      expect(report.saved, 2);
      expect(report.failed, 1);
      expect(report.message, '2 ek kaydedildi, 1 ek kaydedilemedi.');
    });

    test('resolvePath istisna fırlatırsa çökmez, başarısız sayılır', () async {
      final downloads = FakeDownloads();
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: (a) async =>
            a.id == 1 ? throw StateError('boom') : Result.ok('/x/${a.id}'),
        downloads: downloads,
      );
      expect(report.saved, 2);
      expect(report.failed, 1);
    });

    test('hiçbiri indirilemezse nedeni söylenir, kaydetme denenmez', () async {
      final downloads = FakeDownloads();
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: (a) async => const Result.err(ConnectionFailure()),
        downloads: downloads,
      );
      expect(downloads.savedNames, isEmpty);
      expect(report.saved, 0);
      expect(report.failed, 3);
      expect(report.message, const ConnectionFailure().userMessage);
    });

    test('yazma hatası başarısız sayılır, kalanlar devam eder', () async {
      final downloads = FakeDownloads(
        outcomes: [DeviceSaveOutcome.failed, DeviceSaveOutcome.saved],
      );
      final report = await saveAttachmentsToDevice(
        attachments: [row(1, 'a.pdf'), row(2, 'b.pdf')],
        resolvePath: resolveAll,
        downloads: downloads,
      );
      expect(report.saved, 1);
      expect(report.failed, 1);
      expect(report.message, '1 ek kaydedildi, 1 ek kaydedilemedi.');
      // Yalnızca gerçekten yazılan dosya bildirilir.
      expect(downloads.notified.single.map((f) => f.name), ['b.pdf']);
    });

    test('kaydedilenler için TEK özet bildirim istenir', () async {
      final downloads = FakeDownloads();
      await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: resolveAll,
        downloads: downloads,
      );
      expect(downloads.notified, hasLength(1));
      expect(downloads.notified.single.map((f) => f.name), [
        'a.pdf',
        'b.xml',
        'c.png',
      ]);
    });

    test('hiçbir şey kaydedilmediyse bildirim istenmez', () async {
      final downloads = FakeDownloads();
      await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: (a) async => const Result.err(ConnectionFailure()),
        downloads: downloads,
      );
      expect(downloads.notified, isEmpty);
    });

    test('boş seçim hiçbir şey yapmaz', () async {
      final downloads = FakeDownloads();
      final report = await saveAttachmentsToDevice(
        attachments: const [],
        resolvePath: resolveAll,
        downloads: downloads,
      );
      expect(downloads.savedNames, isEmpty);
      expect(report.message, isNull);
    });
  });

  group('Android 9 ve altı: seçiciye düşme', () {
    test('unsupported olunca KALAN dosyalar da seçiciyle kaydedilir', () async {
      final downloads = FakeDownloads(
        outcomes: [DeviceSaveOutcome.unsupported],
      );
      final picked = <String>[];
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: resolveAll,
        downloads: downloads,
        saveAs: (f) async {
          picked.add(f.fileName);
          return true;
        },
      );
      // İlk dosyada unsupported alındı; sonrakiler için tekrar denenmez.
      expect(downloads.savedNames, ['a.pdf']);
      expect(picked, ['a.pdf', 'b.xml', 'c.png']);
      expect(report.mode, BatchSaveMode.picker);
      expect(report.saved, 3);
      expect(report.message, '3 ek kaydedildi.');
    });

    test(
      'kullanıcı seçiciyi kapatırsa toplu kayıt durur, hata sayılmaz',
      () async {
        final downloads = FakeDownloads(
          outcomes: [DeviceSaveOutcome.unsupported],
        );
        var calls = 0;
        final report = await saveAttachmentsToDevice(
          attachments: three,
          resolvePath: resolveAll,
          downloads: downloads,
          saveAs: (f) async => ++calls == 1,
        );
        expect(calls, 2);
        expect(report.saved, 1);
        expect(report.failed, 0);
      },
    );

    test('seçici vazgeçilince hiç kaydedilmediyse bildirim yok', () async {
      final downloads = FakeDownloads(
        outcomes: [DeviceSaveOutcome.unsupported],
      );
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: resolveAll,
        downloads: downloads,
        saveAs: (f) async => false,
      );
      expect(report.message, isNull);
    });
  });

  group('iOS ve diğerleri: tek paylaşım sayfası', () {
    test('hazır tüm dosyalar TEK çağrıda paylaşılır', () async {
      final downloads = FakeDownloads(direct: false);
      List<BatchSaveFile>? shared;
      Rect? origin;
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: resolveAll,
        downloads: downloads,
        shareOrigin: const Rect.fromLTWH(1, 2, 3, 4),
        share: (files, o) async {
          shared = files;
          origin = o;
        },
      );
      expect(downloads.savedNames, isEmpty);
      expect(shared!.map((f) => f.fileName), ['a.pdf', 'b.xml', 'c.png']);
      expect(origin, const Rect.fromLTWH(1, 2, 3, 4));
      expect(report.mode, BatchSaveMode.share);
      expect(report.message, isNull);
    });

    test('paylaşım hatası kullanıcıya bildirilir', () async {
      final report = await saveAttachmentsToDevice(
        attachments: three,
        resolvePath: resolveAll,
        downloads: FakeDownloads(direct: false),
        share: (files, o) async => throw StateError('x'),
      );
      expect(report.saved, 0);
      expect(report.failed, 3);
      expect(report.message, 'Ekler kaydedilemedi.');
    });
  });
}
