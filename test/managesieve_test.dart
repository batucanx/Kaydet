import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sender_filter_sync.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/managesieve_service.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/use_cases/sieve_block.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Gerçek bir ManageSieve sunucusu gibi konuşan, soketsiz sahte sunucu: istemcinin gönderdiği komutları
/// ayrıştırır ve Dovecot gibi yanıtlar.
class FakeSieveServer {
  FakeSieveServer({
    Map<String, String>? scripts,
    this.active,
    this.starttls = true,
    this.sasl = 'PLAIN LOGIN',
    this.sieve = 'fileinto vacation envelope',
    this.rejectAuth = false,
    this.username = 'info@pazarlik.com.tr',
    this.password = 'sifre',
  }) : scripts = {...?scripts};

  final Map<String, String> scripts;
  String? active;
  final bool starttls;
  final String sasl;
  final String sieve;
  final bool rejectAuth;
  final String username;
  final String password;

  final List<String> log = [];
  bool tls = false;
  bool? authenticatedOverTls;
  bool closed = false;
  int connections = 0;

  Uint8List _inbox = Uint8List(0);
  final List<Uint8List> _outbox = [];
  Completer<Uint8List>? _waiting;

  String _capabilities() => [
    '"IMPLEMENTATION" "Dovecot Pigeonhole"',
    '"SIEVE" "$sieve"',
    if (starttls && !tls) '"STARTTLS"',
    '"SASL" "${tls || !starttls ? sasl : ''}"',
  ].map((l) => '$l\r\n').join();

  void _push(String text) {
    final chunk = Uint8List.fromList(utf8.encode(text));
    final w = _waiting;
    if (w != null) {
      _waiting = null;
      w.complete(chunk);
    } else {
      _outbox.add(chunk);
    }
  }

  /// Yeni bağlantı: temiz (TLS'siz, kimliksiz) bir oturum, yeteneklerle selamlar.
  SieveTransport transport() {
    connections++;
    tls = false;
    closed = false;
    _inbox = Uint8List(0);
    _outbox.clear();
    _waiting = null;
    _push('${_capabilities()}OK "ready"\r\n');
    return _Transport(this);
  }

  void _write(List<int> data) {
    _inbox = Uint8List.fromList([..._inbox, ...data]);
    for (;;) {
      final text = utf8.decode(_inbox, allowMalformed: true);
      final eol = text.indexOf('\r\n');
      if (eol < 0) return;
      final line = text.substring(0, eol);
      final literal = RegExp(r'\{(\d+)\+?\}$').firstMatch(line);
      String? content;
      var consumed = utf8.encode(line).length + 2;
      if (literal != null) {
        final size = int.parse(literal.group(1)!);
        if (_inbox.length < consumed + size + 2) return;
        content = utf8.decode(_inbox.sublist(consumed, consumed + size));
        consumed += size + 2;
      }
      _inbox = Uint8List.sublistView(_inbox, consumed);
      _handle(line.replaceAll(RegExp(r' \{\d+\+?\}$'), ''), content);
    }
  }

  void _handle(String line, String? content) {
    final parts = RegExp(r'"(?:[^"\\]|\\.)*"|\S+').allMatches(line).map((m) => m.group(0)!).toList();
    final cmd = parts.isEmpty ? '' : parts.first.toUpperCase();
    String arg(int i) => i + 1 < parts.length
        ? parts[i + 1].replaceAll(RegExp(r'^"|"$'), '').replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!)
        : '';
    log.add(cmd == 'AUTHENTICATE' ? 'AUTHENTICATE' : line);
    switch (cmd) {
      case 'STARTTLS':
        _push('OK "Begin TLS negotiation now."\r\n');
      case 'AUTHENTICATE':
        authenticatedOverTls = tls;
        final creds = utf8.decode(base64.decode(arg(1))).split('\u0000');
        _push(
          rejectAuth || creds[1] != username || creds[2] != password
              ? 'NO "Authentication failed."\r\n'
              : 'OK "Logged in."\r\n',
        );
      case 'LISTSCRIPTS':
        _push(
          '${scripts.keys.map((n) => '"$n"${n == active ? ' ACTIVE' : ''}\r\n').join()}OK "Listscripts completed."\r\n',
        );
      case 'GETSCRIPT':
        final script = scripts[arg(0)];
        _push(
          script == null
              ? 'NO "No such script."\r\n'
              : '{${utf8.encode(script).length}}\r\n$script\r\nOK "Getscript completed."\r\n',
        );
      case 'CHECKSCRIPT':
        _push(
          (content ?? '').contains('SYNTAX ERROR')
              ? 'NO "line 1: syntax error"\r\n'
              : 'OK "Checkscript completed."\r\n',
        );
      case 'PUTSCRIPT':
        scripts[arg(0)] = content ?? '';
        _push('OK "Putscript completed."\r\n');
      case 'SETACTIVE':
        active = arg(0);
        _push('OK "Setactive completed."\r\n');
      case 'LOGOUT':
        _push('OK "Logout completed."\r\n');
      default:
        _push('NO "Unknown command"\r\n');
    }
  }
}

class _Transport implements SieveTransport {
  _Transport(this._server);
  final FakeSieveServer _server;

  @override
  Future<void> write(List<int> data) async => _server._write(data);

  @override
  Future<Uint8List> read() {
    if (_server._outbox.isNotEmpty) return Future.value(_server._outbox.removeAt(0));
    final c = Completer<Uint8List>();
    _server._waiting = c;
    return c.future;
  }

  @override
  Future<void> startTls() async {
    _server.tls = true;
    _server._push('${_server._capabilities()}OK "TLS active"\r\n');
  }

  @override
  void close() => _server.closed = true;
}

void main() {
  const user =
      'require ["fileinto"];\nif header :contains "subject" "invoice" {\n  fileinto "Billing";\n}\n';

  group('ManageSieveService', () {
    ManageSieveService serviceFor(FakeSieveServer s) =>
        ManageSieveService(openTransport: (_, _) async => s.transport());

    Future<SenderFilterOutcome> apply(
      FakeSieveServer s,
      List<String> emails, {
      String junk = 'INBOX.Junk',
    }) => serviceFor(s).apply(
      host: 'mail.pazarlik.com.tr',
      username: 'info@pazarlik.com.tr',
      password: 'sifre',
      emails: emails,
      junkMailbox: junk,
    );

    test('etkin betiğe Kaydet bloğunu ekler, kullanıcının kurallarına dokunmaz, bir kez yedek alır', () async {
      final s = FakeSieveServer(scripts: {'main': user}, active: 'main');
      expect(await apply(s, ['Noisy@Spam.Example']), SenderFilterOutcome.applied);

      final script = s.scripts['main']!;
      expect(script, contains(sieveBegin));
      expect(script, contains('if header :contains "subject" "invoice"'));
      expect(script, contains('fileinto "INBOX.Junk"'));
      expect(readBlockedSendersBlock(script), ['noisy@spam.example']);
      expect(s.active, 'main');
      expect(s.scripts[kaydetBackupName], user);
    });

    test('parola yalnızca TLS sonrasında gider ve oturum kapatılır', () async {
      final s = FakeSieveServer(scripts: {'main': user}, active: 'main');
      await apply(s, ['a@x.com']);
      expect(s.authenticatedOverTls, isTrue);
      expect(s.log.indexOf('STARTTLS'), lessThan(s.log.indexOf('AUTHENTICATE')));
      expect(s.log, contains('LOGOUT'));
      expect(s.closed, isTrue);
      expect(s.log.join('\n'), isNot(contains('sifre')));
    });

    test('blok zaten doğruysa yeniden yazılmaz; yedek asla ezilmez', () async {
      final s = FakeSieveServer(scripts: {'main': user}, active: 'main');
      await apply(s, ['a@x.com']);
      s.log.clear();
      expect(await apply(s, ['A@x.com']), SenderFilterOutcome.unchanged);
      expect(s.log.any((l) => l.startsWith('PUTSCRIPT')), isFalse);
      await apply(s, ['a@x.com', 'b@x.com']);
      expect(s.scripts[kaydetBackupName], user);
    });

    test('son engel kalkınca blok çıkar ve kullanıcının betiği aynen geri gelir', () async {
      final s = FakeSieveServer(scripts: {'main': user}, active: 'main');
      await apply(s, ['a@x.com']);
      expect(await apply(s, const []), SenderFilterOutcome.applied);
      expect(s.scripts['main'], user);
      expect(await apply(s, const []), SenderFilterOutcome.unchanged);
    });

    test('kullanıcının betiği yoksa kendi betiğini oluşturup etkinleştirir', () async {
      final s = FakeSieveServer();
      expect(await apply(s, ['a@x.com']), SenderFilterOutcome.applied);
      expect(readBlockedSendersBlock(s.scripts[kaydetScriptName]!), ['a@x.com']);
      expect(s.active, kaydetScriptName);
    });

    test('kaldıracak bir şey ve betik yoksa hiçbir şey yazılmaz', () async {
      final s = FakeSieveServer();
      expect(await apply(s, const []), SenderFilterOutcome.unchanged);
      expect(s.scripts, isEmpty);
    });

    test('sunucunun derlemediği betik saklanmaz ve hata bildirilir', () async {
      final s = FakeSieveServer(scripts: {'main': 'SYNTAX ERROR'}, active: 'main');
      await expectLater(apply(s, ['a@x.com']), throwsA(isA<SieveCommandFailed>()));
      expect(s.scripts['main'], 'SYNTAX ERROR');
      expect(s.scripts.containsKey(kaydetBackupName), isFalse);
    });

    for (final c in <(String, FakeSieveServer Function())>[
      ('STARTTLS yok', () => FakeSieveServer(scripts: {'main': user}, active: 'main', starttls: false)),
      ('PLAIN yok', () => FakeSieveServer(scripts: {'main': user}, active: 'main', sasl: 'LOGIN')),
      ('fileinto yok', () => FakeSieveServer(scripts: {'main': user}, active: 'main', sieve: 'vacation')),
      ('giriş reddedildi', () => FakeSieveServer(scripts: {'main': user}, active: 'main', rejectAuth: true)),
    ]) {
      test('${c.$1}: "unsupported", hiçbir şeye dokunulmaz', () async {
        final s = c.$2();
        expect(await apply(s, ['a@x.com']), SenderFilterOutcome.unsupported);
        expect(s.scripts['main'], user);
        expect(s.log.join('\n'), isNot(contains('sifre')));
      });
    }

    test('bağlantı kurulamazsa "unsupported"', () async {
      final service = ManageSieveService(
        openTransport: (_, _) async => throw const SieveUnavailable('yok'),
      );
      expect(
        await service.apply(
          host: 'x',
          username: 'u',
          password: 'p',
          emails: ['a@x.com'],
          junkMailbox: 'Junk',
        ),
        SenderFilterOutcome.unsupported,
      );
    });

    test('CRLF betikler CRLF kalır', () async {
      final crlf = user.replaceAll('\n', '\r\n');
      final s = FakeSieveServer(scripts: {'main': crlf}, active: 'main');
      await apply(s, ['a@x.com']);
      expect(s.scripts['main']!.replaceAll('\r\n', ''), isNot(contains('\n')));
      await apply(s, const []);
      expect(s.scripts['main'], crlf);
    });
  });

  group('SenderFilterSync', () {
    late AppDatabase db;
    late FakeImapService imap;
    late MailConnection connection;
    late int accountId;
    late FakeSieveServer server;
    late SenderFilterSync sync;
    var now = DateTime.utc(2026, 10, 6, 10);

    setUp(() async {
      now = DateTime.utc(2026, 10, 6, 10);
      db = createTestDatabase();
      imap = FakeImapService();
      final secureStore = InMemorySecureStore();
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'info@pazarlik.com.tr',
          username: 'info@pazarlik.com.tr',
          imapHost: 'mail.pazarlik.com.tr',
          smtpHost: 'mail.pazarlik.com.tr',
        ),
      );
      await secureStore.writePassword(accountId, 'sifre');
      connection = MailConnection(
        database: db,
        secureStore: secureStore,
        imapService: imap,
        keepAlive: false,
      );
      // İstenmeyen klasörünü yerel veritabanına işler.
      await SyncEngine(database: db, connection: connection).syncMailboxes(accountId);
      server = FakeSieveServer(scripts: {'main': user}, active: 'main');
      sync = SenderFilterSync(
        database: db,
        connection: connection,
        service: ManageSieveService(openTransport: (_, _) async => server.transport()),
        now: () => now,
      );
    });

    tearDown(() async {
      sync.dispose();
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    test('listeyi İstenmeyen klasörünün sunucudaki yoluyla uygular', () async {
      await db.insertBlockedSender(accountId: accountId, email: 'b@x.com');
      await db.insertBlockedSender(accountId: accountId, email: 'a@x.com');
      expect(await sync.sync(accountId), SenderFilterSyncResult.applied);
      final script = server.scripts['main']!;
      expect(readBlockedSendersBlock(script), ['a@x.com', 'b@x.com']);
      expect(script, contains('fileinto "INBOX.Junk"'));
    });

    test('kimse engelli değilse (zorlanmadıkça) sunucuya bağlanılmaz; zorlanınca kural kalkar', () async {
      expect(await sync.sync(accountId), SenderFilterSyncResult.skipped);
      expect(server.connections, 0);
      final blocked = (await db.insertBlockedSender(accountId: accountId, email: 'a@x.com')).row;
      await sync.sync(accountId);
      await db.deleteBlockedSender(blocked.id);
      expect(await sync.sync(accountId, force: true), SenderFilterSyncResult.applied);
      expect(server.scripts['main'], user);
    });

    test('aynı liste iki kez uygulanmaz; değişen liste uygulanır', () async {
      await db.insertBlockedSender(accountId: accountId, email: 'a@x.com');
      await sync.sync(accountId);
      expect(await sync.sync(accountId), SenderFilterSyncResult.skipped);
      await db.insertBlockedSender(accountId: accountId, email: 'b@x.com');
      expect(await sync.sync(accountId), SenderFilterSyncResult.applied);
    });

    test('filtrelenemeyen sunucu bir süre rahat bırakılır, sonra yeniden denenir', () async {
      server = FakeSieveServer(scripts: {'main': user}, active: 'main', starttls: false);
      await db.insertBlockedSender(accountId: accountId, email: 'a@x.com');
      expect(await sync.sync(accountId), SenderFilterSyncResult.unsupported);
      expect(await sync.sync(accountId), SenderFilterSyncResult.skipped);
      now = now.add(const Duration(minutes: 61));
      expect(await sync.sync(accountId), SenderFilterSyncResult.unsupported);
      expect(server.connections, 2);
    });

    test('derlenmeyen betikte hata bildirilir ve sonraki istek yeniden dener', () async {
      server = FakeSieveServer(scripts: {'main': 'SYNTAX ERROR'}, active: 'main');
      await db.insertBlockedSender(accountId: accountId, email: 'a@x.com');
      expect(await sync.sync(accountId), SenderFilterSyncResult.failed);
      expect(await sync.sync(accountId), SenderFilterSyncResult.failed);
      expect(server.connections, 2);
    });
  });
}
