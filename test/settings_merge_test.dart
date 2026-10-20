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
      final future = jsonEncode({...doc(9).toJson(), 'v': 6});
      expect(
        pickLatestSettings([serializeSettingsDocument(doc(2)), future]),
        isA<NewerSettings>(),
      );
    });

    test('v1 belge (şablonsuz) okunur; yazılan belge v4 ve şablonları taşır', () {
      final v1 = jsonEncode({
        'format': 'kaydet-settings',
        'v': 1,
        'rev': 1,
        'updatedAt': 'x',
        'writer': 'mobile',
        'labels': <String, Object?>{},
        'signatures': <String, Object?>{},
      });
      final old = pickLatestSettings([v1]);
      expect(old, isA<FoundSettings>());
      expect((old as FoundSettings).document.data.templates, isEmpty);

      const withTemplate = SettingsDocument(
        rev: 2,
        updatedAt: '2026-10-02T10:00:00.000Z',
        writer: 'mobile',
        data: SettingsData(
          templates: {
            't1': {'title': 'Merhaba', 'content': 'Selam', 'isBuiltIn': false},
          },
        ),
      );
      expect(withTemplate.toJson()['v'], 4);
      expect((old).document.data.blockedSenders, isEmpty);
      final back = pickLatestSettings([serializeSettingsDocument(withTemplate)]);
      expect(
        (back as FoundSettings).document.data.templates['t1'],
        {'title': 'Merhaba', 'content': 'Selam', 'isBuiltIn': false},
      );
    });

    test('v2 belge (engelsiz) okunur; engellenen kullanıcılar v3 olarak gidip gelir', () {
      final v2 = jsonEncode({
        'format': 'kaydet-settings',
        'v': 2,
        'rev': 1,
        'updatedAt': 'x',
        'writer': 'web',
        'labels': <String, Object?>{},
        'signatures': <String, Object?>{},
        'templates': <String, Object?>{},
      });
      final old = pickLatestSettings([v2]);
      expect((old as FoundSettings).document.data.blockedSenders, isEmpty);

      const withBlocked = SettingsDocument(
        rev: 2,
        updatedAt: '2026-10-02T10:00:00.000Z',
        writer: 'mobile',
        data: SettingsData(
          blockedSenders: {
            'a@x.com': {'email': 'a@x.com', 'name': 'Ayşe'},
          },
        ),
      );
      final back = pickLatestSettings([serializeSettingsDocument(withBlocked)]);
      expect(
        (back as FoundSettings).document.data.blockedSenders['a@x.com'],
        {'email': 'a@x.com', 'name': 'Ayşe'},
      );
    });

    test('v3 belge (kişisiz) okunur; kişiler v4 olarak gidip gelir', () {
      final v3 = jsonEncode({
        'format': 'kaydet-settings',
        'v': 3,
        'rev': 1,
        'updatedAt': 'x',
        'writer': 'web',
        'labels': <String, Object?>{},
        'signatures': <String, Object?>{},
        'templates': <String, Object?>{},
        'blockedSenders': <String, Object?>{},
      });
      final old = pickLatestSettings([v3]);
      expect((old as FoundSettings).document.data.contacts, isEmpty);

      const withContacts = SettingsDocument(
        rev: 2,
        updatedAt: '2026-10-02T10:00:00.000Z',
        writer: 'mobile',
        data: SettingsData(
          contacts: {
            'a@x.com': {'email': 'a@x.com', 'name': 'Ayşe'},
          },
        ),
      );
      final back = pickLatestSettings([serializeSettingsDocument(withContacts)]);
      expect(
        (back as FoundSettings).document.data.contacts['a@x.com'],
        {'email': 'a@x.com', 'name': 'Ayşe'},
      );
    });

    const filterRecord = {
      'name': 'Faturalar',
      'enabled': true,
      'position': 0,
      'matchMode': 'all',
      'conditions': [
        {'field': 'from', 'operator': 'contains', 'value': 'fatura@example.com'},
      ],
      'actions': [
        {'type': 'label', 'label': 'kaydet_fatura'},
      ],
      'stopProcessing': false,
      'gelecekAlan': {'x': 1},
    };

    test('filtresiz belge v4 yazılır ve `filters` anahtarı hiç yoktur', () {
      final json = doc(1).toJson();
      expect(json['v'], 4);
      expect(json.containsKey('filters'), isFalse);
      expect(settingsVersion, 5);
    });

    test('filtreli belge v5 yazılır; filtre kaydı (bilinmeyen alanlar dahil) aynen gidip gelir', () {
      const withFilter = SettingsDocument(
        rev: 2,
        updatedAt: '2026-10-02T10:00:00.000Z',
        writer: 'mobile',
        data: SettingsData(filters: {'f1': filterRecord}),
      );
      final text = serializeSettingsDocument(withFilter);
      expect((jsonDecode(text) as Map)['v'], 5);
      final back = (pickLatestSettings([text]) as FoundSettings).document;
      expect(back.data.filters['f1'], filterRecord);
      expect(serializeSettingsDocument(back), text);
    });

    test('v4 belge okunur: filters boş sayılır', () {
      final v4 = jsonEncode({
        'format': 'kaydet-settings', 'v': 4, 'rev': 1, 'updatedAt': 'x',
        'writer': 'web', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
      });
      expect((pickLatestSettings([v4]) as FoundSettings).document.data.filters, isEmpty);
    });

    test('v5 belge okunur', () {
      final v5 = jsonEncode({
        'format': 'kaydet-settings', 'v': 5, 'rev': 1, 'updatedAt': 'x',
        'writer': 'web', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
        'filters': {'f1': filterRecord},
      });
      expect((pickLatestSettings([v5]) as FoundSettings).document.data.filters, {'f1': filterRecord});
    });

    test('v6 = newer; geçersiz filters koleksiyonu belgeyi geçersiz kılar', () {
      final v6 = jsonEncode({
        'format': 'kaydet-settings', 'v': 6, 'rev': 1, 'updatedAt': 'x',
        'writer': 'web', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
      });
      expect(pickLatestSettings([v6]), isA<NewerSettings>());
      final bad = jsonEncode({
        'format': 'kaydet-settings', 'v': 5, 'rev': 1, 'updatedAt': 'x',
        'writer': 'web', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
        'filters': {'f1': 'kayıt değil'},
      });
      expect(pickLatestSettings([bad]), isA<NoSettings>());
    });

    test('bilinmeyen üst düzey alanlar düşürülmez', () {
      final text = jsonEncode({
        'format': 'kaydet-settings', 'v': 5, 'rev': 1, 'updatedAt': 'x',
        'writer': 'web', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
        'gelecek': {'a': 1},
      });
      final back = (pickLatestSettings([text]) as FoundSettings).document;
      expect(back.toJson()['gelecek'], {'a': 1});
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

  group('mergeSettings — kişiler', () {
    SettingsData book(List<(String, String)> names) => SettingsData(
      contacts: {
        for (final (email, name) in names) email: {'email': email, 'name': name},
      },
    );

    test('bir tarafta eklenen kişi diğerine geçer; iki taraftaki eklemeler korunur', () {
      final base = book([('a@x.com', 'A')]);
      final r = mergeSettings(
        base: base,
        local: book([('a@x.com', 'A'), ('b@x.com', 'B')]),
        remote: book([('a@x.com', 'A'), ('c@x.com', 'C')]),
      );
      expect(r.merged.contacts.keys.toList(), ['a@x.com', 'b@x.com', 'c@x.com']);
      expect(r.pushNeeded, isTrue);
      expect(r.localChanged, isTrue);
    });

    test('burada silinen kişi orada da silinir; orada verilen ad bizim silmemize üstün gelir', () {
      final base = book([('a@x.com', 'A'), ('b@x.com', 'B')]);
      final r = mergeSettings(
        base: base,
        local: book([('b@x.com', 'B')]),
        remote: book([('a@x.com', 'A'), ('b@x.com', 'B')]),
      );
      expect(r.merged.contacts.keys.toList(), ['b@x.com']);
      final renamedThere = mergeSettings(
        base: base,
        local: book([('b@x.com', 'B')]),
        remote: book([('a@x.com', 'Ayşe'), ('b@x.com', 'B')]),
      );
      expect(renamedThere.merged.contacts['a@x.com'], {'email': 'a@x.com', 'name': 'Ayşe'});
    });

    test('yeni cihaz (ata yok) sunucunun defterini alır ve kendi fazlalıklarını korur', () {
      final r = mergeSettings(
        base: null,
        local: book([('x@x.com', 'X')]),
        remote: book([('a@x.com', 'A')]),
      );
      expect(r.merged.contacts.keys.toList(), ['a@x.com', 'x@x.com']);
    });
  });
}
