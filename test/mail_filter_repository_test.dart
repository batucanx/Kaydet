import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_filter_repository.dart';
import 'package:kaydet/domain/use_cases/filter_rules.dart';

import 'helpers/test_db.dart';

FilterDefinition _def(
  String name, {
  bool enabled = true,
  List<FilterAction>? actions,
}) => FilterDefinition(
  name: name,
  enabled: enabled,
  matchMode: FilterMatchMode.any,
  conditions: const [
    FilterCondition(
      field: FilterField.from,
      operator: FilterOperator.contains,
      value: 'fatura@example.com',
    ),
    FilterCondition(
      field: FilterField.attachment,
      operator: FilterOperator.exists,
    ),
  ],
  actions: actions ?? const [FilterAction.archive()],
  stopProcessing: true,
);

void main() {
  late AppDatabase db;
  late MailFilterRepository repo;
  late int accountId;
  final changed = <int>[];

  setUp(() async {
    db = createTestDatabase();
    changed.clear();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'a@b.com',
        username: 'a@b.com',
        imapHost: 'h',
        smtpHost: 'h',
      ),
    );
    repo = MailFilterRepository(database: db, onChanged: changed.add);
  });
  tearDown(() => db.close());

  test('şema 20: tablo oluşur, varsayılan filtre yoktur', () async {
    expect(db.schemaVersion, 22);
    expect(await repo.list(accountId), isEmpty);
    expect(await repo.count(accountId), 0);
  });

  test('ekle: sona eklenir, tanım gidiş-dönüşte aynı kalır', () async {
    final a = await repo.add(accountId, _def(' Fatura '));
    final b = await repo.add(
      accountId,
      _def(
        'İkinci',
        actions: const [FilterAction.spam(), FilterAction.label(3)],
      ),
    );
    expect(a.ok && b.ok, isTrue);
    expect(changed, [accountId, accountId]);
    final list = await repo.list(accountId);
    expect(list.map((f) => f.name), ['Fatura', 'İkinci']);
    expect(list.map((f) => f.position), [0, 1]);
    expect(list[0].matchMode, FilterMatchMode.any);
    expect(list[0].conditions.length, 2);
    expect(list[0].conditions[1].hasValue, isFalse);
    expect(list[0].stopProcessing, isTrue);
    expect(list[1].actions, const [FilterAction.spam(), FilterAction.label(3)]);
    expect(
      list[0].id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(list[0].id, isNot(list[1].id));
  });

  test('geçersiz tanım kaydedilmez ve eşitleme istenmez', () async {
    final r = await repo.add(
      accountId,
      _def('x', actions: const [FilterAction.spam(), FilterAction.trash()]),
    );
    expect(r.ok, isFalse);
    expect(r.violations.single.toString(), 'actions.1:conflict');
    expect(await repo.count(accountId), 0);
    expect(changed, isEmpty);
  });

  test('en çok 100 filtre', () async {
    for (var i = 0; i < filterMaxPerAccount; i++) {
      expect((await repo.add(accountId, _def('f$i'))).ok, isTrue);
    }
    final r = await repo.add(accountId, _def('fazla'));
    expect(r.limitReached, isTrue);
    expect(await repo.count(accountId), 100);
  });

  test('güncelle: sıra ve oluşturulma korunur; yoksa notFound', () async {
    final a = (await repo.add(accountId, _def('A'))).filter!;
    await repo.add(accountId, _def('B'));
    final u = await repo.update(accountId, a.id, _def('A2', enabled: false));
    expect(u.filter!.name, 'A2');
    expect(u.filter!.enabled, isFalse);
    expect(u.filter!.position, 0);
    expect(u.filter!.createdAt, a.createdAt);
    expect((await repo.update(accountId, 'yok', _def('x'))).notFound, isTrue);
  });

  test('aç/kapat, sil, yeniden sırala', () async {
    final a = (await repo.add(accountId, _def('A'))).filter!;
    final b = (await repo.add(accountId, _def('B'))).filter!;
    final c = (await repo.add(accountId, _def('C'))).filter!;
    expect(await repo.setEnabled(accountId, b.id, false), isTrue);
    expect((await repo.byId(accountId, b.id))!.enabled, isFalse);
    await repo.reorder(accountId, [c.id, a.id, b.id]);
    expect((await repo.list(accountId)).map((f) => f.name), ['C', 'A', 'B']);
    expect((await repo.list(accountId)).map((f) => f.position), [0, 1, 2]);
    expect(await repo.delete(accountId, a.id), isTrue);
    expect(await repo.delete(accountId, a.id), isFalse);
    expect((await repo.list(accountId)).map((f) => f.name), ['C', 'B']);
  });

  test(
    'belgeden put/removeById eşitlemeyi tetiklemez; hesaplar ayrıdır',
    () async {
      final other = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'x@y.com',
          username: 'x',
          imapHost: 'h',
          smtpHost: 'h',
        ),
      );
      await repo.put(accountId, 'abc', _def('Belge'), position: 7);
      await repo.put(other, 'abc', _def('Diğer'), position: 0);
      expect(changed, isEmpty);
      expect((await repo.byId(accountId, 'abc'))!.position, 7);
      expect((await repo.byId(other, 'abc'))!.name, 'Diğer');
      await repo.put(accountId, 'abc', _def('Belge2'), position: 1);
      expect((await repo.list(accountId)).single.name, 'Belge2');
      expect(await repo.removeById(accountId, 'abc'), isTrue);
      expect(await repo.count(other), 1);
    },
  );

  test('hesap silinince filtreleri de gider', () async {
    await repo.add(accountId, _def('A'));
    await db.customStatement('DELETE FROM accounts WHERE id = $accountId');
    expect(await repo.count(accountId), 0);
  });

  test('forward adresi normalleştirilir (küçük harf, kırpılmış)', () async {
    final r = await repo.add(
      accountId,
      _def(
        'F',
        actions: const [FilterAction.forward(' Muhasebe@Example.com ')],
      ),
    );
    expect(r.filter!.actions.single.email, 'muhasebe@example.com');
  });

  test(
    'göç 19 → 20: eski veritabanı açılınca tablo oluşur, veri korunur',
    () async {
      final dir = Directory.systemTemp.createTempSync('kaydet_mig');
      final file = File('${dir.path}/k.sqlite');
      try {
        var old = AppDatabase.forTesting(NativeDatabase(file));
        final id = await old.insertAccount(
          AccountsCompanion.insert(
            email: 'a@b.com',
            username: 'a',
            imapHost: 'h',
            smtpHost: 'h',
          ),
        );
        await old.customStatement('DROP TABLE mail_filters');
        // v21'de eklenen kolonlar eski şemada yoktu; yoksa `addColumn` çakışır.
        for (final column in const [
          'smtp_accepted_at',
          'smtp_reply',
          'sent_verified_at',
          'delivery_failed_at',
          'delivery_failure_reason',
        ]) {
          await old.customStatement('ALTER TABLE messages DROP COLUMN $column');
        }
        await old.customStatement('PRAGMA user_version = 19');
        await old.close();

        old = AppDatabase.forTesting(NativeDatabase(file));
        final migrated = MailFilterRepository(database: old);
        expect(await migrated.count(id), 0);
        expect((await migrated.add(id, _def('Yeni'))).ok, isTrue);
        expect((await old.allAccounts()).single.email, 'a@b.com');
        await old.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'göç 20 → 22: gönderim onayı ve teslim hatası kolonları eklenir, veri korunur',
    () async {
      final dir = Directory.systemTemp.createTempSync('kaydet_mig21');
      final file = File('${dir.path}/k.sqlite');
      try {
        var old = AppDatabase.forTesting(NativeDatabase(file));
        await old.insertAccount(
          AccountsCompanion.insert(
            email: 'a@b.com',
            username: 'a',
            imapHost: 'h',
            smtpHost: 'h',
          ),
        );
        for (final column in const [
          'smtp_accepted_at',
          'smtp_reply',
          'sent_verified_at',
          'delivery_failed_at',
          'delivery_failure_reason',
        ]) {
          await old.customStatement('ALTER TABLE messages DROP COLUMN $column');
        }
        await old.customStatement('PRAGMA user_version = 20');
        await old.close();

        old = AppDatabase.forTesting(NativeDatabase(file));
        final rows = await old
            .customSelect(
              'SELECT smtp_accepted_at, smtp_reply, sent_verified_at, '
              'delivery_failed_at, delivery_failure_reason FROM messages',
            )
            .get();
        expect(rows, isEmpty);
        expect((await old.allAccounts()).single.email, 'a@b.com');
        await old.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
