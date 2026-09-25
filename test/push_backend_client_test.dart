import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/push_backend_client.dart';

class _Seen {
  _Seen(this.method, this.path, this.auth, this.body);

  final String method;
  final String path;
  final String? auth;
  final Map<String, Object?> body;
}

void main() {
  late HttpServer server;
  late List<_Seen> seen;
  late int nextStatus;
  late HttpPushBackendClient client;

  setUp(() async {
    seen = [];
    nextStatus = 204;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      seen.add(
        _Seen(
          request.method,
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader),
          raw.isEmpty ? {} : jsonDecode(raw) as Map<String, Object?>,
        ),
      );
      request.response.statusCode = nextStatus;
      await request.response.close();
    });
    client = HttpPushBackendClient(
      PushBackendConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'gizli-anahtar',
      ),
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  const account = RemotePushAccount(
    apnsToken: 'ab',
    environment: 'development',
    clientAccountId: 3,
    host: 'imap.example.com',
    port: 993,
    secure: true,
    username: 'me@example.com',
    password: 'hunter2',
  );

  test('hesabı sunucu sözleşmesine uygun PUT ile gönderir', () async {
    await client.upsertAccount(account);

    final request = seen.single;
    expect(request.method, 'PUT');
    expect(request.path, '/v1/accounts');
    expect(request.auth, 'Bearer gizli-anahtar');
    expect(request.body, {
      'apnsToken': 'ab',
      'environment': 'development',
      'clientAccountId': 3,
      'imap': {'host': 'imap.example.com', 'port': 993, 'secure': true},
      'username': 'me@example.com',
      'password': 'hunter2',
    });
  });

  test('hesap ve cihaz silme isteklerini gönderir', () async {
    await client.deleteAccount(apnsToken: 'ab', clientAccountId: 3);
    await client.deleteDevice('ab');

    expect(seen[0].method, 'DELETE');
    expect(seen[0].path, '/v1/accounts');
    expect(seen[0].body, {'apnsToken': 'ab', 'clientAccountId': 3});
    expect(seen[1].method, 'DELETE');
    expect(seen[1].path, '/v1/devices');
    expect(seen[1].body, {'apnsToken': 'ab'});
  });

  test('2xx dışı yanıtta durum koduyla hata fırlatır', () async {
    nextStatus = 401;
    await expectLater(
      client.upsertAccount(account),
      throwsA(
        isA<PushBackendException>().having((e) => e.statusCode, 'kod', 401),
      ),
    );
  });

  test('yalnızca isteğin kendisiyle ilgili 4xx "reddedildi" sayılır', () {
    expect(const PushBackendException(400).isRequestRejected, isTrue);
    expect(const PushBackendException(401).isRequestRejected, isFalse);
    expect(const PushBackendException(429).isRequestRejected, isFalse);
    expect(const PushBackendException(503).isRequestRejected, isFalse);
  });

  test('https olmayan (loopback dışı) adrese şifre göndermez', () async {
    final insecure = HttpPushBackendClient(
      const PushBackendConfig(baseUrl: 'http://example.com', apiKey: 'k'),
    );
    await expectLater(insecure.upsertAccount(account), throwsStateError);
    insecure.close();
    expect(seen, isEmpty);
  });

  test('yapılandırma yoksa özellik kapalıdır', () {
    // `--dart-define` verilmeden çalışan testte derleme zamanı değerleri boştur.
    expect(PushBackendConfig.compiled, isNull);
  });
}
