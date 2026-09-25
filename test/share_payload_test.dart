import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/models/share_payload.dart';
import 'package:kaydet/domain/use_cases/share_attachment_policy.dart';
import 'package:path/path.dart' as p;

void main() {
  const root = '/data/share_inbox';
  const id = '3f2b8c1e-9d4a-4b7e-8a11-0c5d6e7f8a9b';

  String manifest({
    Object? idValue = id,
    List<Object?>? files,
    List<Object?>? issues,
    Map<String, Object?> extra = const {},
  }) => jsonEncode({
    'version': 1,
    'id': idValue,
    'source': 'android-share',
    'receivedAtMs': 1758800000000,
    'files':
        files ??
        [
          {'fileName': 'foto.jpg', 'mimeType': 'image/jpeg', 'sizeBytes': 2048},
        ],
    'issues': ?issues,
    ...extra,
  });

  group('SharePayload.tryParse', () {
    test('dosya yolunu manifestten değil root/id/ad üçlüsünden türetir', () {
      final payload = SharePayload.tryParse(manifest(), root: root)!;

      expect(payload.id, id);
      expect(payload.source, 'android-share');
      expect(payload.directory, p.join(root, id));
      expect(payload.files.single.path, p.join(root, id, 'foto.jpg'));
      expect(payload.files.single.mimeType, 'image/jpeg');
      expect(payload.files.single.sizeBytes, 2048);
      expect(
        payload.receivedAt,
        DateTime.fromMillisecondsSinceEpoch(1758800000000, isUtc: true),
      );
    });

    test('birden çok dosyada paylaşım sırası korunur', () {
      final payload = SharePayload.tryParse(
        manifest(
          files: [
            for (final n in ['c.jpg', 'a.jpg', 'b.jpg'])
              {'fileName': n, 'mimeType': 'image/jpeg', 'sizeBytes': 1},
          ],
        ),
        root: root,
      )!;

      expect(payload.files.map((f) => f.fileName), ['c.jpg', 'a.jpg', 'b.jpg']);
    });

    test('yol geçişi içeren dosya adları sessizce elenir', () {
      final payload = SharePayload.tryParse(
        manifest(
          files: [
            for (final n in [
              '../../etc/passwd',
              '..',
              '.',
              'a/b.jpg',
              r'a\b.jpg',
              '',
              'null\u0000.jpg',
              'yeni\nsatir.jpg',
            ])
              {'fileName': n, 'mimeType': 'image/jpeg', 'sizeBytes': 1},
            {'fileName': 'temiz.jpg', 'mimeType': 'image/jpeg', 'sizeBytes': 1},
          ],
        ),
        root: root,
      )!;

      expect(payload.files.map((f) => f.fileName), ['temiz.jpg']);
    });

    test('yol ayırıcı ya da nokta içeren kimlik reddedilir', () {
      for (final bad in [
        '../..',
        'a/b',
        '..',
        '',
        'kisa',
        'x' * 65,
        'a.b.c.d.e.f',
      ]) {
        expect(
          SharePayload.tryParse(manifest(idValue: bad), root: root),
          isNull,
          reason: '"$bad" kimlik olarak kabul edilmemeli',
        );
      }
      expect(SharePayload.tryParse(manifest(idValue: 42), root: root), isNull);
    });

    test('bozuk JSON / beklenmeyen tür null döner, fırlatmaz', () {
      expect(SharePayload.tryParse('{yarim', root: root), isNull);
      expect(SharePayload.tryParse('[]', root: root), isNull);
      expect(SharePayload.tryParse('"metin"', root: root), isNull);
      expect(
        SharePayload.tryParse(
          manifest(files: ['dosya-degil', 3, null]),
          root: root,
        )!.files,
        isEmpty,
      );
    });

    test('MIME türü yoksa application/octet-stream varsayılır', () {
      final payload = SharePayload.tryParse(
        manifest(
          files: [
            {'fileName': 'x.bin', 'sizeBytes': 3},
          ],
        ),
        root: root,
      )!;
      expect(payload.files.single.mimeType, 'application/octet-stream');
    });

    test('hata kodları ve metin/konu alanları okunur', () {
      final payload = SharePayload.tryParse(
        manifest(
          files: [],
          issues: [
            {'code': 'tooLarge', 'fileName': 'film.mov'},
            {'code': 'garip-bir-kod'},
          ],
          extra: {'text': 'https://ornek.com', 'subject': 'Sayfa'},
        ),
        root: root,
      )!;

      expect(payload.issues.map((i) => i.code), [
        ShareIssueCode.tooLarge,
        ShareIssueCode.unknown,
      ]);
      expect(payload.issues.first.fileName, 'film.mov');
      expect(payload.text, 'https://ornek.com');
      expect(payload.subject, 'Sayfa');
      expect(payload.hasText, isTrue);
      expect(payload.isEmpty, isFalse);
    });

    test('hiçbir şey taşımayan paylaşım boş sayılır', () {
      final payload = SharePayload.tryParse(manifest(files: []), root: root)!;
      expect(payload.isEmpty, isTrue);
    });
  });

  group('ShareAttachmentPolicy', () {
    test('sınırın tam üstü reddedilir, sınırın kendisi kabul edilir', () {
      expect(
        ShareAttachmentPolicy.rejectionFor(
          fileName: 'a.pdf',
          sizeBytes: ShareAttachmentPolicy.maxFileBytes,
        ),
        isNull,
      );
      expect(
        ShareAttachmentPolicy.rejectionFor(
          fileName: 'a.pdf',
          sizeBytes: ShareAttachmentPolicy.maxFileBytes + 1,
        ),
        ShareIssueCode.tooLarge,
      );
    });

    test('boş dosya reddedilir', () {
      expect(
        ShareAttachmentPolicy.rejectionFor(fileName: 'a.pdf', sizeBytes: 0),
        ShareIssueCode.empty,
      );
    });

    test(
      'yürütülebilir türler, büyük/küçük harf ve çift uzantıdan bağımsız',
      () {
        for (final name in [
          'setup.exe',
          'SETUP.EXE',
          'fatura.pdf.exe',
          'a.apk',
        ]) {
          expect(
            ShareAttachmentPolicy.rejectionFor(fileName: name, sizeBytes: 10),
            ShareIssueCode.blockedType,
            reason: name,
          );
        }
        for (final name in [
          'foto.jpg',
          'rapor.pdf',
          'notlar.txt',
          'exe',
          '.env',
        ]) {
          expect(
            ShareAttachmentPolicy.rejectionFor(fileName: name, sizeBytes: 10),
            isNull,
            reason: name,
          );
        }
      },
    );

    test(
      'describe: tek dosya için adı içeren, çoğu için özet cümle üretir',
      () {
        expect(ShareAttachmentPolicy.describe(const []), isNull);
        expect(
          ShareAttachmentPolicy.describe(const [
            ShareIssue(code: ShareIssueCode.tooLarge, fileName: 'film.mov'),
          ]),
          contains('“film.mov” çok büyük'),
        );
        expect(
          ShareAttachmentPolicy.describe(const [
            ShareIssue(code: ShareIssueCode.unreadable),
          ]),
          startsWith('Dosya okunamadığı'),
        );
        expect(
          ShareAttachmentPolicy.describe(const [
            ShareIssue(code: ShareIssueCode.tooLarge, fileName: 'a'),
            ShareIssue(code: ShareIssueCode.blockedType, fileName: 'b'),
          ]),
          startsWith('2 dosya eklenemedi'),
        );
      },
    );
  });
}
