import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/push_backend_client.dart';

/// `GET /v1/accounts` yanıtının (bkz. backend/src/app.ts) istemcide nasıl
/// yorumlandığı: sunucunun hesap başına bildirdiği GERÇEK izleme durumu ve
/// durum bildirmeyen eski sunucu uyumluluğu.
void main() {
  late HttpServer server;
  late Object responseBody;
  late HttpPushBackendClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(responseBody));
      await request.response.close();
    });
    client = HttpPushBackendClient(
      PushBackendConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'key',
      ),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('hesap başına izleme durumunu çözer', () async {
    responseBody = {
      'clientAccountIds': [1, 2, 3, 4, 5, 6],
      'accounts': [
        {'clientAccountId': 1, 'status': 'watching'},
        {'clientAccountId': 2, 'status': 'connecting'},
        {'clientAccountId': 3, 'status': 'auth_failed'},
        {'clientAccountId': 4, 'status': 'unreachable'},
        {'clientAccountId': 5, 'status': 'stopped'},
        {'clientAccountId': 6, 'status': 'gelecekte-eklenen-bir-durum'},
      ],
    };

    final accounts = await client.listRegisteredAccounts('ab' * 32);

    expect({for (final a in accounts) a.clientAccountId: a.status}, {
      1: ServerWatchStatus.watching,
      2: ServerWatchStatus.connecting,
      3: ServerWatchStatus.authFailed,
      4: ServerWatchStatus.unreachable,
      5: ServerWatchStatus.stopped,
      6: ServerWatchStatus.unknown,
    });
  });

  test('durum bildirmeyen eski sunucu: kimlikler unknown (onarım tetiklemez)', () async {
    responseBody = {
      'clientAccountIds': [7, 8],
    };

    final accounts = await client.listRegisteredAccounts('ab' * 32);

    expect(accounts.map((a) => a.clientAccountId), [7, 8]);
    expect(
      accounts.every((a) => a.status == ServerWatchStatus.unknown),
      isTrue,
    );
    expect(accounts.any((a) => a.status.isUnhealthy), isFalse);
  });

  test('boş yanıt boş liste döner', () async {
    responseBody = {'clientAccountIds': <int>[], 'accounts': <Object>[]};
    expect(await client.listRegisteredAccounts('ab' * 32), isEmpty);
  });

  test('hangi durumların sağlıksız / onarılabilir olduğu', () {
    const unhealthy = {
      ServerWatchStatus.authFailed,
      ServerWatchStatus.unreachable,
      ServerWatchStatus.stopped,
    };
    for (final status in ServerWatchStatus.values) {
      expect(status.isUnhealthy, unhealthy.contains(status), reason: '$status');
    }
    expect(ServerWatchStatus.authFailed.repairableByReupload, isTrue);
    expect(ServerWatchStatus.stopped.repairableByReupload, isTrue);
    // Sunucunun ağ sorunu şifre göndererek düzelmez.
    expect(ServerWatchStatus.unreachable.repairableByReupload, isFalse);
    expect(ServerWatchStatus.watching.repairableByReupload, isFalse);
  });
}
