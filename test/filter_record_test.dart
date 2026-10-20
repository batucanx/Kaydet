import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/filter_record.dart';
import 'package:kaydet/domain/use_cases/filter_rules.dart';

Map<String, Object?> _record({
  Object? name = 'Fatura',
  Object? position = 0,
  List<Object?>? actions,
  List<Object?>? conditions,
}) => {
  'name': name,
  'enabled': true,
  'position': position,
  'matchMode': 'all',
  'conditions':
      conditions ??
      [
        {'field': 'from', 'operator': 'contains', 'value': 'a@b.com'},
      ],
  'actions':
      actions ??
      [
        {'type': 'archive'},
      ],
  'stopProcessing': false,
};

FolderIndex _folders() => FolderIndex.of([
  (id: 1, path: 'INBOX', delimiter: '.', role: SpecialUse.inbox),
  (id: 2, path: 'INBOX.Faturalar', delimiter: '.', role: SpecialUse.custom),
  (id: 3, path: 'INBOX.Çöp', delimiter: '.', role: SpecialUse.trash),
  (id: 4, path: 'Arşiv', delimiter: '', role: SpecialUse.archive),
]);

ResolveRefs _refs({FolderIndex? folders, String? own = 'ben@kaydet.app'}) =>
    ResolveRefs(
      folders: folders ?? _folders(),
      labelIdOf: (key) => key == 'kaydet_fatura' ? 7 : null,
      ownAddress: own,
    );

void main() {
  group('folderSegments', () {
    test(
      'ayraç "." ve "/" aynı parçaları verir; ayraçsız sunucuda tek parça',
      () {
        expect(folderSegments('INBOX.Faturalar', '.'), ['INBOX', 'Faturalar']);
        expect(folderSegments('INBOX/Faturalar', '/'), ['INBOX', 'Faturalar']);
        expect(folderSegments('Arşiv', ''), ['Arşiv']);
        expect(folderSegments('A.B.C', '.'), ['A', 'B', 'C']);
      },
    );
  });

  group('parseSharedFilter', () {
    test(
      'sözleşmedeki örnek biçim kabul edilir, tam sayı olan ondalık konum da',
      () {
        expect(parseSharedFilter(_record()), isNotNull);
        expect(parseSharedFilter(_record(position: 3.0))!.position, 3);
      },
    );

    test(
      'tanınmayan eylem, geçersiz konum/ad/yol kaydı BÜTÜNÜYLE kullanılamaz yapar',
      () {
        Object? parse(Map<String, Object?> r) => parseSharedFilter(r);
        expect(
          parse(
            _record(
              actions: [
                {'type': 'yeni-eylem'},
              ],
            ),
          ),
          isNull,
        );
        expect(parse(_record(position: -1)), isNull);
        expect(parse(_record(position: 1.5)), isNull);
        expect(parse(_record(position: '1')), isNull);
        expect(parse(_record(position: 1000001)), isNull);
        expect(parse(_record(name: 'x' * 101)), isNull);
        expect(parse(_record(name: 'a\nb')), isNull);
        expect(parse(_record(name: null)), isNull);
        expect(parse(_record(conditions: [])), isNull);
        expect(
          parse(
            _record(
              conditions: [
                {'field': 'from', 'operator': 'contains'},
              ],
            ),
          ),
          isNull,
        );
        expect(
          parse(
            _record(
              actions: [
                {'type': 'move', 'folder': <String>[]},
              ],
            ),
          ),
          isNull,
        );
        expect(
          parse(
            _record(
              actions: [
                {
                  'type': 'move',
                  'folder': ['INBOX', ''],
                },
              ],
            ),
          ),
          isNull,
        );
        expect(
          parse(
            _record(
              actions: [
                {'type': 'move', 'folder': List.filled(17, 'a')},
              ],
            ),
          ),
          isNull,
        );
        expect(
          parse(
            _record(
              actions: [
                {'type': 'forward', 'email': 'ab'},
              ],
            ),
          ),
          isNull,
        );
      },
    );

    test('bilinmeyen alanlar yargılanmaz', () {
      expect(parseSharedFilter({..._record(), 'gelecek': 1}), isNotNull);
    });
  });

  group('toSharedRecord', () {
    FilterDefinition def(List<FilterAction> actions) => FilterDefinition(
      name: 'F',
      enabled: false,
      matchMode: FilterMatchMode.any,
      conditions: const [
        FilterCondition(
          field: FilterField.attachment,
          operator: FilterOperator.notExists,
        ),
      ],
      actions: actions,
      stopProcessing: true,
    );

    test('sabit alan sırası ve taşınabilir adlar', () {
      final record = toSharedRecord(
        def([
          const FilterAction.move(2),
          const FilterAction.label(7),
          const FilterAction.spam(),
        ]),
        3,
        folderPathById: _folders().pathById,
        labelKeyById: {7: 'kaydet_fatura'},
      );
      expect(record!.keys.toList(), [
        'name',
        'enabled',
        'position',
        'matchMode',
        'conditions',
        'actions',
        'stopProcessing',
      ]);
      expect(record['position'], 3);
      expect(record['conditions'], [
        {'field': 'attachment', 'operator': 'notExists'},
      ]);
      expect(record['actions'], [
        {
          'type': 'move',
          'folder': ['INBOX', 'Faturalar'],
        },
        {'type': 'label', 'label': 'kaydet_fatura'},
        {'type': 'spam'},
      ]);
    });

    test(
      'klasörü ya da etiketi hesapta olmayan filtre tarif edilemez (null)',
      () {
        expect(
          toSharedRecord(
            def([const FilterAction.move(99)]),
            0,
            folderPathById: _folders().pathById,
            labelKeyById: const {},
          ),
          isNull,
        );
        expect(
          toSharedRecord(
            def([const FilterAction.label(99)]),
            0,
            folderPathById: _folders().pathById,
            labelKeyById: const {},
          ),
          isNull,
        );
      },
    );
  });

  group('resolveSharedRecord', () {
    Resolution resolve(List<Object?> actions, {ResolveRefs? refs}) =>
        resolveSharedRecord(_record(actions: actions), refs ?? _refs());

    test('klasör ve etiket yerel kimliğe çözülür', () {
      final r =
          resolve([
                {
                  'type': 'move',
                  'folder': ['INBOX', 'Faturalar'],
                },
                {'type': 'label', 'label': 'kaydet_fatura'},
                {'type': 'forward', 'email': ' Muhasebe@X.com '},
              ])
              as ResolvedOk;
      expect(r.filter.definition.actions, [
        const FilterAction.move(2),
        const FilterAction.label(7),
        const FilterAction.forward('muhasebe@x.com'),
      ]);
    });

    test(
      'yol tam eşitlikle eşleşir: büyük/küçük harf ve eksik parça çözülmez',
      () {
        expect(
          resolve([
            {
              'type': 'move',
              'folder': ['INBOX', 'faturalar'],
            },
          ]),
          isA<ResolvedUnresolved>(),
        );
        expect(
          resolve([
            {
              'type': 'move',
              'folder': ['Faturalar'],
            },
          ]),
          isA<ResolvedUnresolved>(),
        );
        expect(
          resolve([
            {
              'type': 'move',
              'folder': ['Arşiv'],
            },
          ]),
          isA<ResolvedOk>(),
        );
      },
    );

    test('etiket yoksa çözülmemiş (ileride gelebilir)', () {
      expect(
        resolve([
          {'type': 'label', 'label': 'kaydet_yok'},
        ]),
        isA<ResolvedUnresolved>(),
      );
    });

    test(
      'Gelen Kutusu bilinmiyorsa (klasör senkronu bitmedi) move çözülmemiş',
      () {
        final noInbox = FolderIndex.of([
          (
            id: 2,
            path: 'INBOX.Faturalar',
            delimiter: '.',
            role: SpecialUse.custom,
          ),
        ]);
        expect(
          resolve([
            {
              'type': 'move',
              'folder': ['INBOX', 'Faturalar'],
            },
          ], refs: _refs(folders: noInbox)),
          isA<ResolvedUnresolved>(),
        );
      },
    );

    test(
      'arayüzün reddettiği kurallar geçersiz; geçersiz çözülmemişe baskın',
      () {
        for (final actions in [
          [
            {
              'type': 'move',
              'folder': ['INBOX', 'Çöp'],
            },
          ],
          [
            {
              'type': 'move',
              'folder': ['INBOX'],
            },
          ],
          [
            {'type': 'forward', 'email': 'BEN@kaydet.app'},
          ],
          [
            {'type': 'spam'},
            {'type': 'delete'},
          ],
          [
            {'type': 'archive'},
            {'type': 'archive'},
          ],
          [
            {'type': 'forward', 'email': 'a@x.com'},
            {'type': 'forward', 'email': 'b@x.com'},
          ],
          [
            {'type': 'label', 'label': 'kaydet_yok'},
            {'type': 'forward', 'email': 'ben@kaydet.app'},
          ],
        ]) {
          expect(resolve(actions), isA<ResolvedInvalid>(), reason: '$actions');
        }
      },
    );

    test(
      'bozuk kayıt geçersiz; adsız kayıt adsız kalır (belge değişmesin)',
      () {
        expect(
          resolve([
            {'type': 'yeni'},
          ]),
          isA<ResolvedInvalid>(),
        );
        final unnamed =
            resolveSharedRecord(_record(name: ''), _refs()) as ResolvedOk;
        expect(unnamed.filter.definition.name, '');
      },
    );
  });

  group('partitionFilters', () {
    test(
      'çalışma sırasındaki ilk 100 kullanılır, fazlası taşınır; sıra (konum, anahtar)',
      () {
        final records = <String, Map<String, Object?>>{
          for (var i = 0; i < 102; i++)
            'k${(101 - i).toString().padLeft(3, '0')}': _record(position: 0),
        };
        final part = partitionFilters(
          records,
          (r) => resolveSharedRecord(r, _refs()),
        );
        expect(part.applicable, hasLength(100));
        expect(part.deferred.keys.toSet(), {'k100', 'k101'});
        expect(part.resolved, hasLength(100));
      },
    );

    test('çözülemeyen kayıtlar taşınan tarafa gider', () {
      final part = partitionFilters({
        'a': _record(),
        'b': _record(
          actions: [
            {
              'type': 'move',
              'folder': ['Yok'],
            },
          ],
        ),
        'c': _record(
          actions: [
            {'type': 'tuhaf'},
          ],
        ),
      }, (r) => resolveSharedRecord(r, _refs()));
      expect(part.applicable.keys, ['a']);
      expect(part.deferred.keys.toSet(), {'b', 'c'});
    });
  });
}
