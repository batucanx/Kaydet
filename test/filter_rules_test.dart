import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/filter_rules.dart';

/// Web ile AYNI tablo: `test/fixtures/filter_vectors.json` (web `packages/domain/src/filters/vectors.json`un kopyası).
/// Her beklenti elle yazılmıştır; telefon değerlendiricisi ve doğrulaması web'le aynı sonucu vermek zorundadır.
void main() {
  final table =
      jsonDecode(File('test/fixtures/filter_vectors.json').readAsStringSync())
          as Map<String, Object?>;

  FilterableAddress addressOf(Object? raw) {
    final m = raw! as Map;
    return FilterableAddress(
      email: m['email']! as String,
      name: m['name']! as String,
    );
  }

  FilterableMail mailOf(Map base, Map over) {
    final m = {...base, ...over};
    return FilterableMail(
      from: addressOf(m['from']),
      to: [for (final a in m['to']! as List) addressOf(a)],
      cc: [for (final a in m['cc']! as List) addressOf(a)],
      subject: m['subject']! as String,
      hasAttachments: m['hasAttachments']! as bool,
      body: m['body'] as String?,
    );
  }

  List<FilterCondition> conditionsOf(Object? raw) => [
    for (final c in raw! as List) FilterCondition.fromJson(c)!,
  ];

  group('ortak vektörler', () {
    for (final v in (table['evaluate']! as List).cast<Map>()) {
      test('evaluate: ${v['name']}', () {
        final result = evaluateFilter(
          v['matchMode'] == 'any' ? FilterMatchMode.any : FilterMatchMode.all,
          conditionsOf(v['conditions']),
          mailOf(table['mail']! as Map, v['mail']! as Map),
        );
        final expected = v['expect']! as Map;
        expect(result.matched, expected['matched']);
        expect(
          result.conditions,
          (expected['conditions']! as List).cast<bool>(),
        );
      });
    }

    for (final v in (table['names']! as List).cast<Map>()) {
      test('name: ${v['expect']}', () {
        expect(defaultFilterName(conditionsOf(v['conditions'])), v['expect']);
      });
    }

    for (final v in (table['validation']! as List).cast<Map>()) {
      test('validate: ${v['name']}', () {
        final actions = <FilterAction>[
          for (final a in v['actions']! as List)
            switch ((a as Map)['type']) {
              'move' => const FilterAction.move(1),
              'label' => FilterAction.label(
                int.parse(
                  (a['labelId']! as String).replaceAll(RegExp('[^0-9]'), ''),
                ),
              ),
              'forward' => FilterAction.forward(a['email']! as String),
              final String t => FilterAction.blank(
                FilterActionType.values.firstWhere((e) => e.name == t),
              ),
              _ => throw StateError('bilinmeyen eylem'),
            },
        ];
        final violations = validateFilterDefinition(actions, {
          ...(v['ownAddresses']! as List).cast<String>(),
        });
        final expected = [
          for (final e in (v['expect']! as List).cast<Map>())
            '${e['field']}:${e['reason'] == 'too_many' ? 'tooMany' : e['reason']}',
        ];
        expect([for (final x in violations) x.toString()], expected);
      });
    }
  });

  group('koşul biçimi (web şeması)', () {
    test('fazladan anahtar, geçersiz işleç ve boş değer reddedilir', () {
      expect(
        FilterCondition.fromJson({
          'field': 'from',
          'operator': 'contains',
          'value': ' a ',
        }),
        const FilterCondition(
          field: FilterField.from,
          operator: FilterOperator.contains,
          value: 'a',
        ),
      );
      Object? parse(Map<String, Object?> m) => FilterCondition.fromJson(m);
      expect(
        parse({'field': 'from', 'operator': 'contains', 'value': ' '}),
        isNull,
      );
      expect(
        parse({'field': 'from', 'operator': 'startsWith', 'value': 'a'}),
        isNull,
      );
      expect(
        parse({'field': 'from', 'operator': 'contains', 'value': 'a', 'x': 1}),
        isNull,
      );
      expect(
        parse({'field': 'attachment', 'operator': 'exists', 'value': 'a'}),
        isNull,
      );
      expect(parse({'field': 'attachment', 'operator': 'contains'}), isNull);
      expect(
        parse({'field': 'subject', 'operator': 'contains', 'value': 'x' * 201}),
        isNull,
      );
      expect(parse({'field': 'cc', 'operator': 'exists'}), isNull);
    });
  });

  group('Türkçe katlama', () {
    FilterableMail subject(String s) => FilterableMail(
      from: const FilterableAddress(email: 'a@b.com'),
      subject: s,
    );
    bool contains(String needle, String s) =>
        evaluateFilter(FilterMatchMode.all, [
          FilterCondition(
            field: FilterField.subject,
            operator: FilterOperator.contains,
            value: needle,
          ),
        ], subject(s)).matched;

    test('I / ı / İ / i ve aksanlar eşit sayılır', () {
      expect(contains('ısparta', 'ISPARTA ŞUBE FİŞİ'), isTrue);
      expect(contains('sube fisi', 'ISPARTA ŞUBE FİŞİ'), isTrue);
      expect(contains('FATURA', 'fatura'), isTrue);
      expect(contains('şahan', 'SAHAN'), isTrue);
    });
  });

  group('gövde', () {
    test('gövde okunamadıysa gövde koşulu eşleşmez (notContains dahil)', () {
      const mail = FilterableMail(from: FilterableAddress(email: 'a@b.com'));
      for (final op in [FilterOperator.contains, FilterOperator.notContains]) {
        expect(
          evaluateFilter(FilterMatchMode.all, [
            FilterCondition(field: FilterField.body, operator: op, value: 'x'),
          ], mail).matched,
          isFalse,
        );
      }
    });
  });

  group('validateFilterForSave', () {
    FilterDefinition def({
      String name = '',
      List<FilterCondition>? conditions,
      List<FilterAction>? actions,
    }) => FilterDefinition(
      name: name,
      enabled: true,
      matchMode: FilterMatchMode.all,
      conditions:
          conditions ??
          const [
            FilterCondition(
              field: FilterField.from,
              operator: FilterOperator.contains,
              value: 'a',
            ),
          ],
      actions: actions ?? const [FilterAction.archive()],
      stopProcessing: false,
    );

    test('geçerli tanım temiz', () {
      expect(validateFilterForSave(def()), isEmpty);
    });
    test('ad: 100 karakter üstü ve denetim karakteri', () {
      expect(validateFilterForSave(def(name: 'x' * 101)).single.field, 'name');
      expect(validateFilterForSave(def(name: 'a\nb')).single.field, 'name');
    });
    test('boş koşul değeri, boş klasör/etiket, kendine iletme', () {
      final v = validateFilterForSave(
        def(
          conditions: const [
            FilterCondition(
              field: FilterField.subject,
              operator: FilterOperator.contains,
              value: '  ',
            ),
          ],
          actions: const [FilterAction.move(0)],
        ),
      );
      expect(v.map((e) => e.field), ['conditions.0.value', 'actions.0']);
      final own = validateFilterForSave(
        def(actions: const [FilterAction.forward('Ben@Kaydet.app')]),
        ownAddresses: {'ben@kaydet.app'},
      );
      expect(own.single.field, 'actions.0.email');
    });
    test('sınırlar: 11 koşul, 11 eylem', () {
      final many = List.filled(
        11,
        const FilterCondition(
          field: FilterField.from,
          operator: FilterOperator.contains,
          value: 'a',
        ),
      );
      expect(
        validateFilterForSave(def(conditions: many)).single.field,
        'conditions',
      );
      expect(
        validateFilterForSave(
          def(actions: List.filled(11, const FilterAction.archive())),
        ).single.field,
        'actions',
      );
    });
  });
}
