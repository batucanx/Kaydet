import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/settings_document.dart';
import 'package:kaydet/domain/use_cases/settings_merge.dart';

/// Web istemcisiyle AYNI test tablosu (`packages/domain/src/settings/vectors.json`
/// dosyasının kopyası). İki gerçekleme birebir aynı sonucu vermek zorundadır;
/// biri değişirse bu tablo ikisinde de güncellenir.
void main() {
  final vectors =
      (jsonDecode(File('test/fixtures/settings_vectors.json').readAsStringSync())
              as List)
          .cast<Map<String, Object?>>();

  SettingsData? data(Object? raw) =>
      raw == null ? null : SettingsData.fromJson(raw as Map<String, Object?>);

  group('mergeSettings — ortak test vektörleri', () {
    for (final v in vectors) {
      test(v['name']! as String, () {
        final expected = v['expect']! as Map<String, Object?>;
        final result = mergeSettings(
          base: data(v['base']),
          local: data(v['local'])!,
          remote: data(v['remote']),
        );
        expect(
          settingsDataEqual(result.merged, data(expected['merged'])!),
          isTrue,
          reason: jsonEncode(result.merged.toJson()),
        );
        expect(result.pushNeeded, expected['pushNeeded']);
        expect(result.localChanged, expected['localChanged']);
      });
    }

    test('idempotent: sonucu kendisiyle birleştirmek hiçbir şey değiştirmez', () {
      for (final v in vectors) {
        final first = mergeSettings(
          base: data(v['base']),
          local: data(v['local'])!,
          remote: data(v['remote']),
        ).merged;
        final second = mergeSettings(base: first, local: first, remote: first);
        expect(settingsDataEqual(second.merged, first), isTrue, reason: v['name']! as String);
        expect(second.pushNeeded, isFalse, reason: v['name']! as String);
        expect(second.localChanged, isFalse, reason: v['name']! as String);
      }
    });
  });

  group('ayar belgesi', () {
    SettingsDocument doc(int rev) => SettingsDocument(
      rev: rev,
      updatedAt: '2026-10-02T10:00:00.000Z',
      writer: 'mobile',
      data: const SettingsData(
        labels: {'kaydet_kisisel': {'name': 'Kişisel', 'tone': 6}},
      ),
    );

    test('JSON gidiş-dönüşü Türkçe metni korur', () {
      final latest = pickLatestSettings([serializeSettingsDocument(doc(3))]);
      expect(latest, isA<FoundSettings>());
      final found = (latest as FoundSettings).document;
      expect(found.rev, 3);
      expect(found.data.labels['kaydet_kisisel'], {'name': 'Kişisel', 'tone': 6});
    });

    test('en yüksek sürüm alınır, bozuk iletiler atlanır', () {
      final latest = pickLatestSettings([
        serializeSettingsDocument(doc(2)),
        serializeSettingsDocument(doc(5)),
        'json değil',
        serializeSettingsDocument(doc(4)),
      ]);
      expect((latest as FoundSettings).document.rev, 5);
    });

    test('geçerli belge yoksa NoSettings; daha yeni biçim varsa NewerSettings', () {
      expect(pickLatestSettings(const []), isA<NoSettings>());
      expect(pickLatestSettings(['{"format":"baska"}', '[]']), isA<NoSettings>());
      final future = jsonEncode({...doc(9).toJson(), 'v': 2});
      expect(
        pickLatestSettings([serializeSettingsDocument(doc(2)), future]),
        isA<NewerSettings>(),
      );
    });

    test('bozuk ya da aşırı büyük belge reddedilir', () {
      expect(
        pickLatestSettings(['{"format":"kaydet-settings","v":1,"rev":-1}']),
        isA<NoSettings>(),
      );
      expect(
        pickLatestSettings([' ' * (settingsMaxChars + 1)]),
        isA<NoSettings>(),
      );
    });

    test('gizli klasör her derinlikte ve her ayraçla tanınır', () {
      expect(isSettingsMailbox('Kaydet-Settings', '/'), isTrue);
      expect(isSettingsMailbox('INBOX.Kaydet-Settings', '.'), isTrue);
      expect(isSettingsMailbox('INBOX/Kaydet-Settings', '/'), isTrue);
      expect(isSettingsMailbox('INBOX.Kaydet-Settings.Alt', '.'), isFalse);
      expect(isSettingsMailbox('INBOX.Not-Kaydet-Settings', '.'), isFalse);
    });

    test('MIME iletisi başlığı ve base64 gövdeyi taşır; gövde geri çözülür', () {
      final text = serializeSettingsDocument(doc(1));
      final mime = buildSettingsMime(
        from: 'ben@example.com',
        text: text,
        date: DateTime.utc(2026, 10, 2, 10),
        messageId: 'abc',
      );
      expect(mime, contains('X-Kaydet-Settings: 1\r\n'));
      expect(mime, contains('Content-Transfer-Encoding: base64\r\n'));
      expect(mime, contains('Date: Fri, 02 Oct 2026 10:00:00 +0000'));
      final body = mime.split('\r\n\r\n').last.replaceAll('\r\n', '');
      expect(utf8.decode(base64.decode(body)), text);
      for (final line in mime.split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(78));
      }
    });
  });
}
