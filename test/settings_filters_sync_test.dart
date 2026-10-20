import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_filter_repository.dart';
import 'package:kaydet/data/repositories/settings_sync_service.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/data/services/settings_sync_state_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/filter_rules.dart';
import 'package:kaydet/domain/use_cases/settings_document.dart';
import 'package:kaydet/domain/use_cases/settings_merge.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Gelen e-posta filtrelerinin ayar belgesiyle eşitlenmesi (sözleşme: web `docs/SETTINGS-FILTERS-CONTRACT.md`).
/// Telefon filtreleri uygulamaz; bu testler yalnızca saklama, çeviri ve "taşınır, silinmez" kuralını sınar.

class _Imap extends FakeImapService {
  @override
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    String? encodedPath,
    List<String> flags = const [],
  }) async {
    final result = await super.appendMessage(
      mimeSource: mimeSource,
      targetPath: targetPath,
      encodedPath: encodedPath,
      flags: flags,
    );
    final uid = (result as Ok<int?>).value!;
    final body = mimeSource.split('\r\n\r\n').last.replaceAll('\r\n', '');
    seedBody(
      targetPath,
      uid,
      FetchedBody(plainText: utf8.decode(base64.decode(body))),
    );
    return result;
  }

  @override
  Future<Result<void>> createMailbox(String path) async {
    if (mailboxes.any((m) => m.path == path)) {
      return const Err(ServerFailure(detail: 'ALREADYEXISTS'));
    }
    return super.createMailbox(path);
  }

  List<String> documentsIn(String path) => [
    for (final uid in (store[path] ?? {}).keys) bodies[path]![uid]!.plainText!,
  ];

  int get appends => commandLog.where((c) => c.startsWith('append')).length;
}

const _settingsBox = 'INBOX.Kaydet-Settings';

class _Device {
  _Device(this.imap, this.accountId, this.db, this.service)
    : filters = MailFilterRepository(database: db);

  final _Imap imap;
  final int accountId;
  final AppDatabase db;
  final SettingsSyncService service;
  final MailFilterRepository filters;

  static Future<_Device> create(
    _Imap imap, {
    Duration retry = const Duration(seconds: 20),
  }) async {
    final db = createTestDatabase();
    final accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    final secureStore = InMemorySecureStore();
    await secureStore.writePassword(accountId, 'sifre');
    final connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
      keepAlive: false,
    );
    final service = SettingsSyncService(
      database: db,
      connection: connection,
      state: MemorySettingsSyncStateStore(),
      deferredRetryBase: retry,
    );
    final device = _Device(imap, accountId, db, service);
    // Gerçek bir hesapta Gelen Kutusu her zaman vardır (klasör hedefleri onun varlığına bağlıdır).
    await device.addFolder('INBOX', use: SpecialUse.inbox);
    return device;
  }

  Future<void> sync() async {
    final result = await service.sync(accountId, force: true);
    expect(result, isA<Ok<void>>(), reason: '$result');
  }

  Future<int> addFolder(
    String path, {
    SpecialUse use = SpecialUse.custom,
    String? encoded,
    String delimiter = '.',
  }) => db.upsertMailbox(
    MailboxesCompanion.insert(
      accountId: accountId,
      path: path,
      name: path.split(delimiter).last,
      encodedPath: Value(encoded ?? path),
      specialUse: Value(use),
      delimiter: Value(delimiter),
    ),
  );

  Future<int> addLabel(String name, {String? keyword}) => db.insertLabel(
    LabelsCompanion.insert(
      accountId: accountId,
      name: name,
      imapKeyword: Value(keyword ?? 'kaydet_${name.toLowerCase()}'),
    ),
  );

  Map<String, Object?>? latestRaw() {
    final box = imap.mailboxes.where(
      (m) => isSettingsMailbox(m.path, m.delimiter),
    );
    if (box.isEmpty) return null;
    final latest = pickLatestSettings(imap.documentsIn(box.first.path));
    return latest is FoundSettings
        ? jsonDecode(serializeSettingsDocument(latest.document))
              as Map<String, Object?>
        : null;
  }

  Map<String, Object?> docFilters() =>
      ((latestRaw()?['filters'] ?? <String, Object?>{}) as Map)
          .cast<String, Object?>();
}

/// Web'in yazdığı belge.
Future<void> _webWrites(
  _Imap imap, {
  Map<String, Map<String, Object?>> filters = const {},
  Map<String, Map<String, Object?>> labels = const {},
  int rev = 1,
}) async {
  if (!imap.mailboxes.any((m) => m.path == _settingsBox)) {
    await imap.createMailbox(_settingsBox);
  }
  final doc = SettingsDocument(
    rev: rev,
    updatedAt: '2026-01-01T00:00:00.000Z',
    writer: 'web',
    data: SettingsData(labels: labels, filters: filters),
  );
  final uid =
      (imap.store[_settingsBox] ?? {}).keys.fold<int>(
        0,
        (a, b) => a > b ? a : b,
      ) +
      1;
  imap.store.putIfAbsent(_settingsBox, () => {})[uid] = envelope(uid: uid);
  imap.seedBody(
    _settingsBox,
    uid,
    FetchedBody(plainText: serializeSettingsDocument(doc)),
  );
}

Map<String, Object?> _webFilter({
  String name = 'Faturalar',
  bool enabled = true,
  int position = 0,
  String matchMode = 'all',
  List<Object?>? conditions,
  List<Object?>? actions,
  bool stop = false,
}) => {
  'name': name,
  'enabled': enabled,
  'position': position,
  'matchMode': matchMode,
  'conditions':
      conditions ??
      [
        {
          'field': 'from',
          'operator': 'contains',
          'value': 'fatura@example.com',
        },
        {'field': 'attachment', 'operator': 'exists'},
      ],
  'actions':
      actions ??
      [
        {'type': 'label', 'label': 'kaydet_fatura'},
        {
          'type': 'move',
          'folder': ['INBOX', 'Faturalar'],
        },
        {'type': 'forward', 'email': 'muhasebe@example.com'},
      ],
  'stopProcessing': stop,
};

FilterDefinition _local({
  String name = 'Yerel',
  List<FilterAction> actions = const [FilterAction.archive()],
  List<FilterCondition>? conditions,
}) => FilterDefinition(
  name: name,
  enabled: true,
  matchMode: FilterMatchMode.all,
  conditions:
      conditions ??
      const [
        FilterCondition(
          field: FilterField.subject,
          operator: FilterOperator.contains,
          value: 'x',
        ),
      ],
  actions: actions,
  stopProcessing: false,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late _Imap imap;
  setUp(() => imap = _Imap());

  group('telefon → belge', () {
    test(
      'klasör çözülmüş parçalarla, etiket anahtarla, rol eylemleri rolle yazılır; yerel kimlik sızmaz',
      () async {
        final phone = await _Device.create(imap);
        final folder = await phone.addFolder(
          'INBOX.Faturalar Şubat',
          encoded: 'INBOX.Faturalar &AV4-ubat',
        );
        final label = await phone.addLabel('Fatura');
        final saved = await phone.filters.add(
          phone.accountId,
          _local(
            name: 'Faturalar',
            actions: [
              FilterAction.move(folder),
              FilterAction.label(label),
              const FilterAction.forward('muhasebe@example.com'),
            ],
          ),
          ownAddresses: {'info@pazarlik.com.tr'},
        );
        await phone.filters.add(
          phone.accountId,
          _local(name: 'Çöp', actions: const [FilterAction.trash()]),
        );
        await phone.sync();

        final raw = phone.latestRaw()!;
        expect(raw['v'], 5);
        final filters = phone.docFilters();
        expect(filters.keys, containsAll([saved.filter!.id]));
        expect(filters[saved.filter!.id], {
          'name': 'Faturalar',
          'enabled': true,
          'position': 0,
          'matchMode': 'all',
          'conditions': [
            {'field': 'subject', 'operator': 'contains', 'value': 'x'},
          ],
          'actions': [
            {
              'type': 'move',
              // Çözülmüş ad; UTF-7 ("&AV4-") DEĞİL.
              'folder': ['INBOX', 'Faturalar Şubat'],
            },
            {'type': 'label', 'label': 'kaydet_fatura'},
            {'type': 'forward', 'email': 'muhasebe@example.com'},
          ],
          'stopProcessing': false,
        });
        final trash =
            filters.values.firstWhere((f) => (f! as Map)['name'] == 'Çöp')
                as Map;
        expect(trash['actions'], [
          {'type': 'trash'},
        ]);
        expect(trash['position'], 1);
        expect(jsonEncode(raw), isNot(contains('"folderId"')));
        expect(jsonEncode(raw), isNot(contains('labelId')));
      },
    );

    test('ayraç "/" olan sunucuda yol aynı parçalara bölünür', () async {
      final phone = await _Device.create(imap);
      final folder = await phone.addFolder('INBOX/Faturalar', delimiter: '/');
      await phone.filters.add(
        phone.accountId,
        _local(actions: [FilterAction.move(folder)]),
      );
      await phone.sync();
      final record = phone.docFilters().values.single! as Map;
      expect((record['actions']! as List).single, {
        'type': 'move',
        'folder': ['INBOX', 'Faturalar'],
      });
    });

    test(
      'değişiklik yoksa belge yeniden yazılmaz; etiket yeniden adlandırılınca kayıt anahtarı izler',
      () async {
        final phone = await _Device.create(imap);
        final label = await phone.addLabel('Fatura');
        await phone.filters.add(
          phone.accountId,
          _local(actions: [FilterAction.label(label)]),
        );
        await phone.sync();
        final appends = imap.appends;
        await phone.sync();
        expect(imap.appends, appends);

        await (phone.db.update(
          phone.db.labels,
        )..where((l) => l.id.equals(label))).write(
          const LabelsCompanion(
            name: Value('Muhasebe'),
            imapKeyword: Value('kaydet_muhasebe'),
          ),
        );
        await phone.sync();
        final record = phone.docFilters().values.single! as Map;
        expect((record['actions']! as List).single, {
          'type': 'label',
          'label': 'kaydet_muhasebe',
        });
      },
    );

    test('düzenleme, açıp kapatma, sıralama ve silme belgeye yansır', () async {
      final phone = await _Device.create(imap);
      final a = (await phone.filters.add(
        phone.accountId,
        _local(name: 'A'),
      )).filter!;
      final b = (await phone.filters.add(
        phone.accountId,
        _local(name: 'B'),
      )).filter!;
      await phone.sync();
      await phone.filters.reorder(phone.accountId, [b.id, a.id]);
      await phone.filters.setEnabled(phone.accountId, a.id, false);
      await phone.sync();
      var docs = phone.docFilters();
      expect((docs[b.id]! as Map)['position'], 0);
      expect((docs[a.id]! as Map)['position'], 1);
      expect((docs[a.id]! as Map)['enabled'], false);

      await phone.filters.delete(phone.accountId, a.id);
      await phone.sync();
      docs = phone.docFilters();
      expect(docs.keys, [b.id]);

      await phone.filters.delete(phone.accountId, b.id);
      await phone.sync();
      // Son filtre gidince belge v4'e döner (filters anahtarı yok).
      expect(phone.latestRaw()!['v'], 4);
      expect(phone.latestRaw()!.containsKey('filters'), isFalse);
    });
  });

  group('belge → telefon', () {
    test(
      'web kaydı yerel kimliklere çevrilir; gidiş-dönüşte belge DEĞİŞMEZ',
      () async {
        final phone = await _Device.create(imap);
        final folder = await phone.addFolder('INBOX.Faturalar');
        final label = await phone.addLabel('Fatura');
        await _webWrites(
          imap,
          labels: {
            'kaydet_fatura': {'name': 'Fatura', 'tone': 0},
          },
          filters: {
            'f-1': _webFilter(),
            'f-2': _webFilter(
              name: 'İkinci',
              position: 1,
              matchMode: 'any',
              enabled: false,
              stop: true,
              actions: [
                {'type': 'archive'},
              ],
            ),
          },
        );
        await phone.sync();

        final list = await phone.filters.list(phone.accountId);
        expect(list.map((f) => f.id), ['f-1', 'f-2']);
        expect(list[0].name, 'Faturalar');
        expect(list[0].matchMode, FilterMatchMode.all);
        expect(list[0].actions, [
          FilterAction.label(label),
          FilterAction.move(folder),
          const FilterAction.forward('muhasebe@example.com'),
        ]);
        expect(list[1].enabled, isFalse);
        expect(list[1].stopProcessing, isTrue);
        expect(list[1].actions, const [FilterAction.archive()]);

        // Telefon belgeyi yeniden yazmadı (hiçbir fark yok) ...
        expect(imap.appends, 0);
        // ... ve başka bir yerel değişiklik de filtreleri değiştirmez.
        await phone.addLabel('Kişisel', keyword: 'kaydet_kisisel');
        await phone.sync();
        final raw = phone.latestRaw()!;
        expect(raw['writer'], 'mobile');
        expect(raw['filters'], {
          'f-1': _webFilter(),
          'f-2': _webFilter(
            name: 'İkinci',
            position: 1,
            matchMode: 'any',
            enabled: false,
            stop: true,
            actions: [
              {'type': 'archive'},
            ],
          ),
        });
      },
    );

    test(
      'klasör henüz yok: kayıt yerele yazılmaz, belgede kalır, belge yeniden yazılmaz; klasör gelince uygulanır',
      () async {
        final phone = await _Device.create(imap);
        await _webWrites(
          imap,
          filters: {
            'f-1': _webFilter(
              actions: [
                {
                  'type': 'move',
                  'folder': ['INBOX', 'Faturalar'],
                },
              ],
            ),
          },
        );
        await phone.sync();
        expect(await phone.filters.count(phone.accountId), 0);
        expect(imap.appends, 0);

        final folder = await phone.addFolder('INBOX.Faturalar');
        await phone.sync();
        final list = await phone.filters.list(phone.accountId);
        expect(list.single.actions, [FilterAction.move(folder)]);
        expect(imap.appends, 0);
      },
    );

    test(
      'kullanılamayan kayıt silinmiş OKUNMAZ: yerel değişiklik yazımı onu belgede korur',
      () async {
        final phone = await _Device.create(imap);
        await phone.addLabel('Is', keyword: 'kaydet_is');
        await _webWrites(
          imap,
          labels: {
            'kaydet_is': {'name': 'Is', 'tone': 0},
          },
          filters: {
            'cozulmez': _webFilter(
              name: 'Klasörü yok',
              actions: [
                {
                  'type': 'move',
                  'folder': ['INBOX', 'Yok'],
                },
              ],
            ),
            'bozuk': {
              ...(_webFilter(name: 'Bozuk', position: 3)),
              'actions': [
                {'type': 'tuhaf-yeni-eylem'},
              ],
            },
            'gelecek': {
              ..._webFilter(
                name: 'Alan',
                position: 4,
                actions: [
                  {'type': 'archive'},
                ],
              ),
              'gelecekAlan': [1],
            },
          },
        );
        await phone.sync();
        await phone.addLabel('Kişisel', keyword: 'kaydet_kisisel');
        await phone.sync();
        await phone.sync();

        final docs = phone.docFilters();
        expect(docs.keys.toSet(), {'cozulmez', 'bozuk', 'gelecek'});
        expect((docs['bozuk']! as Map)['actions'], [
          {'type': 'tuhaf-yeni-eylem'},
        ]);
        expect((docs['gelecek']! as Map)['gelecekAlan'], [1]);
        // Çözülmüş (iyi biçimli) olanlar birleştirmeye girdi: 0..n-1; bozuk olan olduğu gibi (3).
        expect((docs['bozuk']! as Map)['position'], 3);
        expect(
          await phone.filters.count(phone.accountId),
          1,
        ); // yalnızca "gelecek" (alan eklentisi yargılanmaz)
      },
    );

    test(
      'arayüzün reddedeceği kurallar yerele yazılmaz ama belgede kalır',
      () async {
        final phone = await _Device.create(imap);
        await phone.addFolder('INBOX', use: SpecialUse.inbox);
        await phone.addFolder('INBOX.Çöp', use: SpecialUse.trash);
        await phone.addFolder('INBOX.Giden', use: SpecialUse.sent);
        final docs = {
          'trasha': _webFilter(
            position: 0,
            actions: [
              {
                'type': 'move',
                'folder': ['INBOX', 'Çöp'],
              },
            ],
          ),
          'gidene': _webFilter(
            position: 1,
            actions: [
              {
                'type': 'move',
                'folder': ['INBOX', 'Giden'],
              },
            ],
          ),
          'gelene': _webFilter(
            position: 2,
            actions: [
              {
                'type': 'move',
                'folder': ['INBOX'],
              },
            ],
          ),
          'kendine': _webFilter(
            position: 3,
            actions: [
              {'type': 'forward', 'email': 'INFO@pazarlik.com.tr'},
            ],
          ),
          'iki': _webFilter(
            position: 4,
            actions: [
              {'type': 'spam'},
              {'type': 'delete'},
            ],
          ),
          'cift': _webFilter(
            position: 5,
            actions: [
              {'type': 'archive'},
              {'type': 'archive'},
            ],
          ),
          'iletme2': _webFilter(
            position: 6,
            actions: [
              {'type': 'forward', 'email': 'a@x.com'},
              {'type': 'forward', 'email': 'b@x.com'},
            ],
          ),
          'iyi': _webFilter(
            position: 7,
            actions: [
              {'type': 'spam'},
            ],
          ),
        };
        await _webWrites(imap, filters: docs);
        await phone.sync();
        expect((await phone.filters.list(phone.accountId)).map((f) => f.id), [
          'iyi',
        ]);
        expect(phone.docFilters().keys.toSet(), docs.keys.toSet());
        expect(imap.appends, 0);
      },
    );

    test(
      'hesap başına en çok 100 filtre: çalışma sırasındaki ilk 100 uygulanır, fazlası belgede kalır',
      () async {
        final phone = await _Device.create(imap);
        await _webWrites(
          imap,
          filters: {
            for (var i = 0; i < 101; i++)
              'f${i.toString().padLeft(3, '0')}': _webFilter(
                name: 'F$i',
                position: i,
                actions: [
                  {'type': 'archive'},
                ],
              ),
          },
        );
        await phone.sync();
        final list = await phone.filters.list(phone.accountId);
        expect(list, hasLength(100));
        expect(list.last.id, 'f099');
        expect(phone.docFilters(), hasLength(101));
        // Sonraki tur 101. filtreyi yerelden silinmiş saymaz.
        await phone.sync();
        expect(phone.docFilters(), hasLength(101));
        expect(await phone.filters.count(phone.accountId), 100);
      },
    );

    test('çalışma sırası birleştirmeden sonra 0..n-1 numaralanır', () async {
      final phone = await _Device.create(imap);
      await _webWrites(
        imap,
        filters: {
          'b': _webFilter(
            position: 9,
            actions: [
              {'type': 'archive'},
            ],
          ),
          'a': _webFilter(
            position: 5,
            actions: [
              {'type': 'archive'},
            ],
          ),
        },
      );
      await phone.sync();
      final list = await phone.filters.list(phone.accountId);
      expect(list.map((f) => '${f.id}:${f.position}'), ['a:0', 'b:1']);
      expect((phone.docFilters()['a']! as Map)['position'], 0);
      expect((phone.docFilters()['b']! as Map)['position'], 1);
    });
  });

  group('iki yönlü', () {
    test(
      'web filtreyi siler: telefondan da gider; telefonda hiç paylaşılmamış filtre silinmez',
      () async {
        final phone = await _Device.create(imap);
        await _webWrites(
          imap,
          filters: {
            'f-1': _webFilter(
              actions: [
                {'type': 'archive'},
              ],
            ),
          },
        );
        await phone.sync();
        expect(await phone.filters.count(phone.accountId), 1);

        // Telefonda yeni bir filtre, hiç paylaşılmadan (etiketi yok → kayıt çıkarılamaz): "orada silindi" sayılmaz.
        final ghost = (await phone.filters.add(
          phone.accountId,
          _local(
            name: 'Paylaşılamaz',
            actions: const [FilterAction.label(9999)],
          ),
        )).filter!;

        await _webWrites(imap, filters: const {}, rev: 5);
        await phone.sync();
        expect((await phone.filters.list(phone.accountId)).map((f) => f.id), [
          ghost.id,
        ]);
        expect(phone.docFilters().containsKey('f-1'), isFalse);
      },
    );

    test(
      'telefon ve web aynı anda farklı filtre ekler: ikisi de korunur',
      () async {
        final phone = await _Device.create(imap);
        await phone.filters.add(phone.accountId, _local(name: 'Telefon'));
        await phone.sync();
        final latest = phone.latestRaw()!;
        // Web, telefonun belgesini görmeden kendi filtresini ekleyen yeni sürüm yazdı.
        await _webWrites(
          imap,
          rev: (latest['rev']! as int) + 1,
          filters: {
            ...phone.docFilters().cast<String, Map<String, Object?>>(),
            'web-1': _webFilter(
              position: 1,
              actions: [
                {'type': 'archive'},
              ],
            ),
          },
        );
        await phone.sync();
        expect((await phone.filters.list(phone.accountId)).length, 2);
      },
    );

    test(
      'yeniden kurulum: boş veritabanı filtreleri belgeden geri alır',
      () async {
        final first = await _Device.create(imap);
        final folder = await first.addFolder('INBOX.Faturalar');
        await first.filters.add(
          first.accountId,
          _local(name: 'Kalıcı', actions: [FilterAction.move(folder)]),
        );
        await first.sync();

        final again = await _Device.create(imap);
        await again.addFolder('INBOX.Faturalar');
        await again.sync();
        final list = await again.filters.list(again.accountId);
        expect(list.single.name, 'Kalıcı');
      },
    );
  });

  group('klasörler gecikmeli gelirse', () {
    test(
      'ertelenen filtre otomatik yeniden denenir (klasör sonradan gelir)',
      () async {
        final phone = await _Device.create(
          imap,
          retry: const Duration(milliseconds: 40),
        );
        await _webWrites(
          imap,
          filters: {
            'f-1': _webFilter(
              actions: [
                {
                  'type': 'move',
                  'folder': ['INBOX', 'Faturalar'],
                },
              ],
            ),
          },
        );
        await phone.sync();
        expect(await phone.filters.count(phone.accountId), 0);

        await phone.addFolder('INBOX.Faturalar');
        for (var i = 0; i < 40; i++) {
          if (await phone.filters.count(phone.accountId) == 1) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await phone.filters.count(phone.accountId), 1);
        phone.service.dispose();
      },
    );
  });

  group('boyut payı', () {
    test(
      '120 KB payı dolunca yeni filtreler yerel kalır, hata yok; belgede zaten olanlar hep paylaşılır',
      () async {
        final phone = await _Device.create(imap);
        final big = List.generate(
          10,
          (i) => FilterCondition(
            field: FilterField.subject,
            operator: FilterOperator.contains,
            value: '${'x' * 190}$i',
          ),
        );
        for (var i = 0; i < 100; i++) {
          final r = await phone.filters.add(
            phone.accountId,
            _local(name: 'Büyük $i', conditions: big),
          );
          expect(r.ok, isTrue);
        }
        await phone.sync();
        final shared = phone.docFilters().length;
        expect(shared, inInclusiveRange(30, 60));
        expect(await phone.filters.count(phone.accountId), 100);
        final doc = jsonEncode(phone.latestRaw());
        expect(doc.length, lessThan(settingsMaxChars));

        // Paylaşılmayanlar sonraki turda silinmiş sayılmaz.
        await phone.sync();
        expect(await phone.filters.count(phone.accountId), 100);
        expect(phone.docFilters().length, shared);
      },
    );
  });
}
