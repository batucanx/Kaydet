import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/settings_sync_service.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/data/services/settings_sync_state_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/settings_document.dart';
import 'package:kaydet/domain/use_cases/settings_merge.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Sahte sunucu: eklenen iletinin base64 gövdesini çözüp `fetchBody` ile geri verir.
class _SettingsImap extends FakeImapService {
  @override
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    List<String> flags = const [],
  }) async {
    final result = await super.appendMessage(
      mimeSource: mimeSource,
      targetPath: targetPath,
      flags: flags,
    );
    final uid = (result as Ok<int?>).value!;
    final body = mimeSource.split('\r\n\r\n').last.replaceAll('\r\n', '');
    seedBody(targetPath, uid, FetchedBody(plainText: utf8.decode(base64.decode(body))));
    return result;
  }

  @override
  Future<Result<void>> createMailbox(String path) async {
    // Gerçek sunucu gibi: aynı yol zaten varsa reddeder.
    if (mailboxes.any((m) => m.path == path)) {
      return const Err(ServerFailure(detail: 'ALREADYEXISTS'));
    }
    return super.createMailbox(path);
  }

  List<String> documentsIn(String path) => [
    for (final uid in (store[path] ?? {}).keys) bodies[path]![uid]!.plainText!,
  ];
}

/// Bir "cihaz": kendi veritabanı ve durumu var, sunucuyu paylaşır.
class _Device {
  _Device(this.imap, this.accountId, this.db, this.service);

  final _SettingsImap imap;
  final int accountId;
  final AppDatabase db;
  final SettingsSyncService service;

  static Future<_Device> create(
    _SettingsImap imap, {
    DateTime Function()? now,
    String writer = 'mobile',
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
      writer: writer,
      now: now,
    );
    return _Device(imap, accountId, db, service);
  }

  Future<void> sync() async {
    final result = await service.sync(accountId, force: true);
    expect(result, isA<Ok<void>>(), reason: '$result');
  }

  Future<void> addLabel(String name, int tone, {String? keyword}) =>
      db.insertLabel(
        LabelsCompanion.insert(
          accountId: accountId,
          name: name,
          toneIndex: Value(tone),
          imapKeyword: Value(keyword ?? 'kaydet_${name.toLowerCase()}'),
        ),
      );

  Future<int> addSignature(
    String name,
    String body, {
    bool isDefault = false,
    String imageType = 'none',
    String? localImagePath,
  }) => db.insertSignature(
    SignaturesCompanion.insert(
      accountId: accountId,
      name: name,
      body: Value(body),
      isDefault: Value(isDefault),
      imageType: Value(imageType),
      localImagePath: Value(localImagePath),
    ),
  );

  Future<List<String>> labels() async => [
    for (final l in await db.labelsOf(accountId)) '${l.name}:${l.toneIndex}',
  ]..sort();

  Future<void> block(String email, {String name = ''}) =>
      db.insertBlockedSender(accountId: accountId, email: email, name: name);

  Future<List<String>> blocked() async => [
    for (final b in await db.blockedSendersOf(accountId)) '${b.email}:${b.name}',
  ]..sort();

  Future<List<String>> signatures() async => [
    for (final s in await db.signaturesOf(accountId))
      '${s.name}:${s.body}:${s.isDefault ? 'D' : '-'}',
  ]..sort();

  SettingsDocument? latestDocument() {
    final box = imap.mailboxes.where((m) => isSettingsMailbox(m.path, m.delimiter));
    if (box.isEmpty) return null;
    final latest = pickLatestSettings(imap.documentsIn(box.first.path));
    return latest is FoundSettings ? latest.document : null;
  }
}

void main() {
  // Her "cihaz" kendi bellek içi veritabanını açar; ortak yürütücü yok.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _SettingsImap imap;

  setUp(() => imap = _SettingsImap());

  test('ilk eşitleme etiket ve imzaları Gelen Kutusu altındaki gizli klasöre yazar', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Kişisel', 6, keyword: 'kaydet_kisisel');
    await a.addSignature('İmza 1', 'Saygılarımla', isDefault: true);

    await a.sync();

    expect(imap.mailboxes.map((m) => m.path), contains('INBOX.Kaydet-Settings'));
    final doc = a.latestDocument()!;
    expect(doc.rev, 1);
    expect(doc.writer, 'mobile');
    expect(doc.data.labels['kaydet_kisisel'], {'name': 'Kişisel', 'tone': 6});
    expect(doc.data.signatures['İmza 1'], containsPair('body', 'Saygılarımla'));
    expect(doc.data.signatures['İmza 1'], containsPair('isDefault', true));
  });

  test('yazma sonrası eski sürümler silinir: sunucuda hep tek ileti kalır', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Bir', 1);
    await a.sync();
    await a.addLabel('Iki', 2);
    await a.sync();
    await a.addLabel('Uc', 3);
    await a.sync();

    expect(imap.documentsIn('INBOX.Kaydet-Settings'), hasLength(1));
    expect(a.latestDocument()!.rev, 3);
  });

  test('değişiklik yoksa hiçbir şey yazılmaz', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Bir', 1);
    await a.sync();
    final before = imap.commandLog.where((c) => c.startsWith('append')).length;
    await a.sync();
    await a.sync();
    expect(imap.commandLog.where((c) => c.startsWith('append')).length, before);
  });

  test('web tarafından yazılan belge yerele iner; anahtar kelime korunur', () async {
    final web = await _Device.create(imap, writer: 'web');
    await web.addLabel('Proje', 4, keyword: 'kaydet_proje');
    await web.addSignature('Web imza', 'Merhaba', isDefault: true);
    await web.sync();

    final phone = await _Device.create(imap);
    await phone.sync();

    expect(await phone.labels(), ['Proje:4']);
    expect((await phone.db.labelsOf(phone.accountId)).single.imapKeyword, 'kaydet_proje');
    expect(await phone.signatures(), ['Web imza:Merhaba:D']);
  });

  test('iki yönlü: ekleme, renk değişikliği ve silme', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.addLabel('Is', 1, keyword: 'kaydet_is');
    await phone.sync();
    await web.sync();

    // web: yeni etiket + "Is" rengini değiştirir
    await web.addLabel('Acil', 9, keyword: 'kaydet_acil');
    final webIs = (await web.db.labelsOf(web.accountId)).firstWhere((l) => l.name == 'Is');
    await web.db.updateLabelRow(webIs.id, const LabelsCompanion(toneIndex: Value(4)));
    await web.sync();
    await phone.sync();
    expect(await phone.labels(), ['Acil:9', 'Is:4']);

    // telefon "Is"i siler
    final phoneIs = (await phone.db.labelsOf(phone.accountId)).firstWhere((l) => l.name == 'Is');
    await phone.db.deleteLabel(phoneIs.id);
    await phone.sync();
    await web.sync();
    expect(await web.labels(), ['Acil:9']);
  });

  test('aynı etiket iki tarafta değişirse son eşitleyen kazanır ve ikisi yakınsar', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.addLabel('Is', 1, keyword: 'kaydet_is');
    await phone.sync();
    await web.sync();

    Future<void> setTone(_Device d, int tone) async {
      final row = (await d.db.labelsOf(d.accountId)).single;
      await d.db.updateLabelRow(row.id, LabelsCompanion(toneIndex: Value(tone)));
    }

    await setTone(phone, 3);
    await setTone(web, 5);
    await phone.sync();
    await web.sync(); // web kendi değişikliğini telefonunkinin üzerine yazar
    await phone.sync();

    expect(await phone.labels(), ['Is:5']);
    expect(await web.labels(), ['Is:5']);
  });

  test('web başka bir etiket adını aynı anahtarla yazarsa yerelin adı güncellenir', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.addLabel('Kisisel', 1, keyword: 'kaydet_kisisel');
    await phone.sync();
    await web.sync();

    final row = (await web.db.labelsOf(web.accountId)).single;
    await web.db.updateLabelRow(row.id, const LabelsCompanion(name: Value('Kişisel')));
    await web.sync();
    await phone.sync();

    expect(await phone.labels(), ['Kişisel:1']);
  });

  test('daha yeni bir biçime sahip belgenin üzerine yazılmaz', () async {
    final a = await _Device.create(imap);
    imap.mailboxes.add(const RemoteMailbox(
      path: 'INBOX.Kaydet-Settings',
      name: 'Kaydet-Settings',
      delimiter: '.',
      specialUse: SpecialUse.custom,
    ));
    imap.store['INBOX.Kaydet-Settings'] = {};
    final future = jsonEncode({
      'format': 'kaydet-settings', 'v': 4, 'rev': 40, 'updatedAt': 'x',
      'writer': 'gelecek', 'labels': <String, Object?>{}, 'signatures': <String, Object?>{},
    });
    await imap.appendMessage(
      mimeSource: 'x\r\n\r\n${base64.encode(utf8.encode(future))}',
      targetPath: 'INBOX.Kaydet-Settings',
    );
    await a.addLabel('Is', 1);
    final appendsBefore = imap.commandLog.where((c) => c.startsWith('append')).length;

    await a.sync();

    expect(imap.commandLog.where((c) => c.startsWith('append')).length, appendsBefore);
    expect(imap.documentsIn('INBOX.Kaydet-Settings'), hasLength(1));
  });

  test('klasör kaybolursa yerel veriden yeniden oluşturulur, "her şey silindi" sayılmaz', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Is', 2);
    await a.sync();
    imap.mailboxes.removeWhere((m) => isSettingsMailbox(m.path, m.delimiter));
    imap.store.remove('INBOX.Kaydet-Settings');

    await a.sync();

    expect(await a.labels(), ['Is:2']);
    expect(a.latestDocument()!.data.labels.keys, contains('kaydet_is'));
  });

  test('cihazdaki görselli imza korunur: karşı taraftaki metin değişse de görsel alanları ezilmez', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    final id = await phone.addSignature('Logolu', 'eski', imageType: 'local', localImagePath: '/data/logo.png');
    await phone.sync();
    // Cihazdaki görsel başka cihaza taşınamaz: belgeye hiç yazılmaz.
    expect(phone.latestDocument()!.data.signatures['Logolu'], isNot(contains('localImagePath')));
    expect(phone.latestDocument()!.data.signatures['Logolu'], isNot(contains('imageType')));
    await web.sync();

    // web metni değiştirir
    final row = (await web.db.signaturesOf(web.accountId)).single;
    await web.db.updateSignatureRow(row.id, const SignaturesCompanion(body: Value('yeni')));
    await web.sync();
    await phone.sync();

    final local = (await phone.db.signaturesOf(phone.accountId)).single;
    expect(local.id, id);
    expect(local.body, 'yeni');
    expect(local.imageType, 'local');
    expect(local.localImagePath, '/data/logo.png');
  });

  test('uzak görselli imza alanları iki yönde taşınır', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.db.insertSignature(
      SignaturesCompanion.insert(
        accountId: phone.accountId,
        name: 'Logolu',
        body: const Value('x'),
        imageType: const Value('remote'),
        remoteImageUrl: const Value('https://example.com/logo.png'),
        imageWidth: const Value(150),
        imagePosition: const Value('top'),
      ),
    );
    await phone.sync();
    await web.sync();

    final s = (await web.db.signaturesOf(web.accountId)).single;
    expect(s.imageType, 'remote');
    expect(s.remoteImageUrl, 'https://example.com/logo.png');
    expect(s.imageWidth, 150);
    expect(s.imagePosition, 'top');
  });

  test('iki cihaz farklı imzayı varsayılan yaparsa en fazla bir varsayılan kalır', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.addSignature('Bir', 'a', isDefault: true);
    await phone.addSignature('Iki', 'b');
    await phone.sync();
    await web.sync();

    Future<void> makeDefault(_Device d, String name) async {
      final row = (await d.db.signaturesOf(d.accountId)).firstWhere((s) => s.name == name);
      await d.db.setDefaultSignature(d.accountId, row.id);
    }

    await makeDefault(phone, 'Iki');
    await phone.sync();
    await web.sync();
    await makeDefault(web, 'Bir');
    await web.sync();
    await phone.sync();

    for (final d in [phone, web]) {
      final defaults = (await d.db.signaturesOf(d.accountId)).where((s) => s.isDefault);
      expect(defaults, hasLength(1));
    }
    expect(await phone.signatures(), await web.signatures());
  });

  test('hasRemoteChange: değişiklik yokken false, başka istemci yazınca true', () async {
    final a = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await a.addLabel('Is', 1);

    expect(await a.service.hasRemoteChange(a.accountId), isTrue, reason: 'durum henüz bilinmiyor');
    await a.sync(); // yazar
    expect(await a.service.hasRemoteChange(a.accountId), isTrue, reason: 'yazımdan sonra durum yeniden öğrenilir');
    await a.sync(); // değişiklik yok: durumu öğrenir
    expect(await a.service.hasRemoteChange(a.accountId), isFalse);

    await web.addLabel('Yeni', 2);
    await web.sync();
    expect(await a.service.hasRemoteChange(a.accountId), isTrue);
    await a.sync();
    expect(await a.service.hasRemoteChange(a.accountId), isFalse);
    expect(await a.labels(), contains('Yeni:2'));
  });

  test('ayar klasörü abonelikten çıkarılır (webmail göstermesin), turlar başına tekrarlanmaz', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Is', 1);
    await a.sync();
    await a.sync();
    expect(imap.unsubscribed, ['INBOX.Kaydet-Settings']);
  });

  test('gizli ayar klasörü klasör listesine girmez', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Is', 1);
    await a.sync();
    expect(imap.mailboxes.any((m) => isSettingsMailbox(m.path, m.delimiter)), isTrue);

    final connection = MailConnection(
      database: a.db,
      secureStore: (InMemorySecureStore()..writePassword(a.accountId, 'sifre')),
      imapService: imap,
      keepAlive: false,
    );
    final engine = SyncEngine(database: a.db, connection: connection);
    final result = await engine.syncMailboxes(a.accountId);

    final paths = (result as Ok<List<MailboxRow>>).value.map((m) => m.path);
    expect(paths, contains('INBOX'));
    expect(paths.where((p) => p.endsWith('Kaydet-Settings')), isEmpty);
  });

  test('eşitleme hatasında saklanan durum değişmez; sonraki deneme başarılı olur', () async {
    final a = await _Device.create(imap);
    await a.addLabel('Is', 2);
    imap.failOnConnect = const ConnectionFailure(detail: 'yok');
    await a.imap.disconnect();

    final failed = await a.service.sync(a.accountId, force: true);
    expect(failed, isA<Err<void>>());

    imap.failOnConnect = null;
    await a.sync();
    expect(a.latestDocument()!.data.labels.keys, contains('kaydet_is'));
  });

  test('art arda tur isteği sıkışmaz: 45 sn içinde zorlanmayan ikinci tur atlanır', () async {
    var clock = DateTime.utc(2026, 10, 2, 10);
    final a = await _Device.create(imap, now: () => clock);
    await a.addLabel('Is', 1);
    await a.sync();
    final lists = imap.commandLog.where((c) => c == 'list').length;

    await a.service.sync(a.accountId); // force yok, 0 sn geçti
    expect(imap.commandLog.where((c) => c == 'list').length, lists);

    clock = clock.add(const Duration(seconds: 60));
    await a.service.sync(a.accountId);
    expect(imap.commandLog.where((c) => c == 'list').length, greaterThan(lists));
  });

  test('engellenen kullanıcılar iki yönde taşınır: engel ve engel kaldırma', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.block('gurultu@spam.example', name: 'Gürültü');
    await phone.sync();
    expect(
      phone.latestDocument()!.data.blockedSenders,
      {
        'gurultu@spam.example': {'email': 'gurultu@spam.example', 'name': 'Gürültü'},
      },
    );

    await web.sync();
    expect(await web.blocked(), ['gurultu@spam.example:Gürültü']);

    final entry = (await web.db.blockedSendersOf(web.accountId)).single;
    await web.db.deleteBlockedSender(entry.id);
    await web.sync();
    await phone.sync();
    expect(phone.latestDocument()!.data.blockedSenders, isEmpty);
    expect(await phone.blocked(), isEmpty);
  });

  test('iki taraf aynı anda farklı adres engellerse ikisi de korunur; tanınmayan kayıt olduğu gibi taşınır', () async {
    final phone = await _Device.create(imap);
    final web = await _Device.create(imap, writer: 'web');
    await phone.sync();
    await web.sync();
    await phone.block('a@spam.example');
    await web.block('b@spam.example');
    await phone.sync();
    await web.sync();
    await phone.sync();
    expect(await phone.blocked(), ['a@spam.example:', 'b@spam.example:']);
    expect(await web.blocked(), ['a@spam.example:', 'b@spam.example:']);

    // Biçimi bozuk bir kayıt yargılanmaz ve silinmez.
    final latest = phone.latestDocument()!;
    final box = imap.mailboxes.firstWhere((m) => isSettingsMailbox(m.path, m.delimiter));
    final broken = SettingsDocument(
      rev: latest.rev + 1,
      updatedAt: latest.updatedAt,
      writer: 'web',
      data: SettingsData(
        blockedSenders: {
          ...latest.data.blockedSenders,
          'Tuhaf Anahtar': {'email': 'adres degil'},
        },
      ),
    );
    final uid = (imap.store[box.path] ?? {}).keys.fold<int>(0, (a, b) => a > b ? a : b) + 1;
    imap.store.putIfAbsent(box.path, () => {})[uid] = envelope(uid: uid);
    imap.seedBody(box.path, uid, FetchedBody(plainText: serializeSettingsDocument(broken)));
    await phone.sync();
    expect(await phone.blocked(), ['a@spam.example:', 'b@spam.example:']);
    expect(phone.latestDocument()!.data.blockedSenders['Tuhaf Anahtar'], {'email': 'adres degil'});
  });
}
