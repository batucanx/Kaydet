@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/share_navigator.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/data/services/share_intake_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// "Paylaş → Kaydet" akışı: gerçek `KaydetApp`, gerçek `ShareNavigator`,
/// gerçek `ShareIntakeService` ve gerçek `ComposeScreen`. Yalnızca native
/// taraf (MethodChannel'ın öbür ucu) ve ağ taklit edilir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ShareIntakeService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late SecureStore secureStore;
  late AppSettingsStore settingsStore;
  late Directory inbox;

  /// Native tarafın diskte tuttuğu tüketilmemiş paylaşım manifestleri.
  late List<String> manifests;

  /// Native tarafa giden çağrılar (`acknowledgeShare`, `discardShare`…).
  late List<MethodCall> calls;

  /// `true` ise native `acknowledgeShare` manifesti silmez — ack'in kaybolduğu
  /// (süreç ölümü gibi) durumu taklit eder.
  var ackIsLost = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();
    settingsStore = await AppSettingsStore.create();
    inbox = Directory.systemTemp.createTempSync('kaydet_share_flow_');
    manifests = [];
    calls = [];
    ackIsLost = false;

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final id = (call.arguments as Map?)?['id'] as String?;
      switch (call.method) {
        case 'takePendingShares':
          return {'root': inbox.path, 'payloads': List<String>.of(manifests)};
        case 'inboxRoot':
          // Süpürme gerçek `dart:io` gerektirir; FakeAsync altında ilerlemez.
          // Süpürücü `share_intake_service_test.dart`ta ayrıca sınanır.
          return null;
        case 'acknowledgeShare':
          if (!ackIsLost) {
            manifests.removeWhere((m) => (jsonDecode(m) as Map)['id'] == id);
          }
          return null;
        case 'discardShare':
          manifests.removeWhere((m) => (jsonDecode(m) as Map)['id'] == id);
          return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await imap.dispose();
    await db.close();
    if (inbox.existsSync()) inbox.deleteSync(recursive: true);
  });

  /// Native tarafın yaptığı gibi: dosyaları paylaşım dizinine yazar, manifesti
  /// "diske koyar". [files] sırası paylaşım sırasıdır.
  String stage(
    String id, {
    Map<String, List<int>> files = const {},
    String? text,
    String? subject,
  }) {
    final dir = Directory(p.join(inbox.path, id))..createSync(recursive: true);
    for (final e in files.entries) {
      File(p.join(dir.path, e.key)).writeAsBytesSync(e.value);
    }
    manifests.add(
      jsonEncode({
        'version': 1,
        'id': id,
        'source': 'android-share',
        'receivedAtMs': DateTime.now().millisecondsSinceEpoch,
        'files': [
          for (final e in files.entries)
            {
              'fileName': e.key,
              'mimeType': 'application/octet-stream',
              'sizeBytes': e.value.length,
            },
        ],
        'text': ?text,
        'subject': ?subject,
      }),
    );
    return id;
  }

  /// Native → Dart "yeni paylaşım hazır" dürtmesi (Android `onNewIntent`).
  Future<void> nudge() => messenger.handlePlatformMessage(
    ShareIntakeService.channelName,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall('onShareReceived'),
    ),
    (_) {},
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<int> addAccount() async {
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
      ),
    );
    await secureStore.writePassword(id, 'sifre');
    return id;
  }

  /// `main.dart`taki `_Bootstrap`ın paylaşımla ilgili kısmının aynısı.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
        ],
        child: const _Bootstrap(),
      ),
    );
    await settle(tester);
  }

  void appTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await body(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    });
  }

  Finder composeTitle() => find.text('Yeni ileti');
  Finder chip(String name) => find.widgetWithText(Chip, name);

  Iterable<String> chipNames(WidgetTester tester) => tester
      .widgetList<Chip>(find.byType(Chip))
      .map((c) => (c.label as Text).data!);

  int callCount(String method) => calls.where((c) => c.method == method).length;

  const idA = 'aaaaaaaa-0000-4000-8000-000000000001';
  const idB = 'bbbbbbbb-0000-4000-8000-000000000002';

  group('soğuk başlangıç', () {
    appTest('paylaşılan dosyalar Yeni İleti\'ye ek olarak, sırayla eklenir', (
      tester,
    ) async {
      stage(
        idA,
        files: {
          'foto3.jpg': [1, 2, 3],
          'foto1.jpg': [1, 2],
          'rapor.pdf': [1],
        },
      );
      await addAccount();

      await pumpApp(tester);

      expect(composeTitle(), findsOneWidget);
      // Mevcut ek bileşeni (Chip listesi) ve paylaşım sırası korunur.
      expect(chipNames(tester), ['foto3.jpg', 'foto1.jpg', 'rapor.pdf']);
      // Kime/Konu boş, kullanıcı doldurabilir.
      expect(callCount('acknowledgeShare'), 1);
      expect(manifests, isEmpty, reason: 'paylaşım tüketildi');
    });

    appTest('paylaşım taslağa yazılır: uygulama kapansa bile ek kaybolmaz', (
      tester,
    ) async {
      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      await addAccount();

      await pumpApp(tester);
      // Otomatik kaydetme 3 sn sonra.
      await tester.pump(const Duration(seconds: 4));

      final drafts = await (db.select(
        db.messages,
      )..where((m) => m.isDraft.equals(true))).get();
      expect(drafts, hasLength(1));
      final attachments = await db.attachmentsOf(drafts.single.id);
      expect(attachments.single.fileName, 'foto.jpg');
      expect(attachments.single.localPath, p.join(inbox.path, idA, 'foto.jpg'));
      expect(attachments.single.isOutgoing, isTrue);
    });

    appTest('paylaşım yokken yazma ekranı açılmaz', (tester) async {
      await addAccount();
      await pumpApp(tester);

      expect(composeTitle(), findsNothing);
      expect(callCount('acknowledgeShare'), 0);
    });

    appTest('metin/bağlantı paylaşımı konu ve gövdeyi doldurur', (
      tester,
    ) async {
      stage(idA, text: 'https://ornek.com/yazi', subject: 'Güzel bir yazı');
      await addAccount();

      await pumpApp(tester);

      expect(composeTitle(), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Güzel bir yazı'), findsOneWidget);
      final body = tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller
          .document
          .toPlainText();
      expect(body, contains('https://ornek.com/yazi'));
      expect(find.byType(Chip), findsNothing);
    });
  });

  group('oturum ve hazırlık', () {
    appTest('hesap yokken paylaşım kaybolmaz; giriş yapılınca teslim edilir', (
      tester,
    ) async {
      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );

      await pumpApp(tester); // hesap yok → giriş ekranı

      expect(composeTitle(), findsNothing);
      expect(
        find.textContaining('önce bir hesapla giriş yapın'),
        findsOneWidget,
      );
      expect(callCount('acknowledgeShare'), 0, reason: 'tüketilmemeli');
      expect(manifests, hasLength(1));

      // Kullanıcı giriş yapar.
      await addAccount();
      await settle(tester);

      expect(composeTitle(), findsOneWidget);
      expect(chip('foto.jpg'), findsOneWidget);
      expect(callCount('acknowledgeShare'), 1);
    });

    appTest('kullanılabilir hiçbir dosya kalmadıysa yazma ekranı açılmaz, '
        'anlaşılır hata gösterilir', (tester) async {
      stage(
        idA,
        files: {
          'kurulum.exe': [1, 2, 3],
        },
      );
      await addAccount();

      await pumpApp(tester);

      expect(composeTitle(), findsNothing);
      expect(
        find.textContaining('“kurulum.exe” güvenlik nedeniyle'),
        findsOneWidget,
      );
      expect(callCount('discardShare'), 1);
      expect(manifests, isEmpty);
    });

    appTest('bir kısmı reddedilirse kalanlar eklenir ve kullanıcı uyarılır', (
      tester,
    ) async {
      stage(
        idA,
        files: {
          'foto.jpg': [1],
          'virus.exe': [1],
          'bos.txt': [],
        },
      );
      await addAccount();

      await pumpApp(tester);

      expect(composeTitle(), findsOneWidget);
      expect(chipNames(tester), ['foto.jpg']);
      expect(find.textContaining('2 dosya eklenemedi'), findsOneWidget);
    });
  });

  group('sıcak başlangıç ve tekrar', () {
    appTest('uygulama açıkken gelen paylaşım (onNewIntent) yazma ekranı açar', (
      tester,
    ) async {
      await addAccount();
      await pumpApp(tester);
      expect(composeTitle(), findsNothing);

      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      await nudge();
      await settle(tester);

      expect(composeTitle(), findsOneWidget);
      expect(chip('foto.jpg'), findsOneWidget);
    });

    appTest('aynı paylaşım için art arda dürtme ikinci ekran AÇMAZ', (
      tester,
    ) async {
      await addAccount();
      await pumpApp(tester);

      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      // Native yeniden başlatma/yaşam döngüsü yüzünden dürtmeler tekrarlanır.
      await nudge();
      await nudge();
      await nudge();
      await settle(tester);

      expect(composeTitle(), findsOneWidget);
      expect(chip('foto.jpg'), findsOneWidget);
      // Yığında tek yazma ekranı: geri dönünce Gelen Kutusu'ndayız.
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await settle(tester);
      expect(composeTitle(), findsNothing);
    });

    appTest('ack kaybolsa bile (süreç içinde) aynı paylaşım tekrar açılmaz', (
      tester,
    ) async {
      ackIsLost = true; // native manifesti silemiyor → her çekişte geri gelir
      await addAccount();
      await pumpApp(tester);

      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      await nudge();
      await settle(tester);
      await nudge();
      await settle(tester);

      expect(composeTitle(), findsOneWidget);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await settle(tester);
      expect(composeTitle(), findsNothing, reason: 'ikinci ekran açılmamalı');
    });

    appTest('uygulama öne gelince (resumed) bekleyen paylaşım alınır', (
      tester,
    ) async {
      await addAccount();
      await pumpApp(tester);

      // iOS: uzantı dosyayı yazdı, ana uygulama URL ile öne getirildi; native
      // dürtme YOK, yalnızca yaşam döngüsü olayı var.
      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);

      expect(composeTitle(), findsOneWidget);
      expect(chip('foto.jpg'), findsOneWidget);
    });

    appTest('iOS: uzantının açtığı kaydetshare:// URL rota olarak AÇILMAZ, '
        'yalnızca bekleyen paylaşımı teslim eder', (tester) async {
      await addAccount();
      await pumpApp(tester);

      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      // Motorun `pushRouteInformation` olarak ilettiği URL (Info.plist'teki
      // FlutterDeepLinkingEnabled kapatılmamış olsa bile).
      await messenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(
          const MethodCall('pushRouteInformation', {
            'location': 'kaydetshare://open',
          }),
        ),
        (_) {},
      );
      await settle(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: 'bilinmeyen rota hatası yok',
      );
      expect(composeTitle(), findsOneWidget);
      expect(chip('foto.jpg'), findsOneWidget);
    });

    appTest('zaten yazma ekranındayken gelen paylaşım yeni ekran açar; '
        'önceki ekran ve içeriği bozulmaz', (tester) async {
      await addAccount();
      await pumpApp(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '').first,
        'ilk@ornek.com',
      );
      await settle(tester);
      expect(composeTitle(), findsOneWidget);

      stage(
        idA,
        files: {
          'foto.jpg': [1, 2, 3],
        },
      );
      await nudge();
      await settle(tester);

      // Üstte ekli yeni ekran.
      expect(chip('foto.jpg'), findsOneWidget);

      // Geri: alttaki ilk yazma ekranı, yazılanla birlikte hâlâ orada.
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await settle(tester);
      expect(composeTitle(), findsOneWidget);
      expect(find.text('ilk@ornek.com'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);
    });

    appTest('iki ayrı paylaşım iki ayrı yazma ekranı açar', (tester) async {
      await addAccount();
      await pumpApp(tester);

      stage(
        idA,
        files: {
          'bir.jpg': [1],
        },
      );
      await nudge();
      await settle(tester);
      stage(
        idB,
        files: {
          'iki.jpg': [1],
        },
      );
      await nudge();
      await settle(tester);

      expect(chip('iki.jpg'), findsOneWidget);
      expect(
        chip('bir.jpg'),
        findsNothing,
        reason: 'üstteki ekranda yalnızca ikinci',
      );
      expect(callCount('acknowledgeShare'), 2);
    });
  });
}

/// `main.dart`taki `_Bootstrap`ın paylaşımla ilgili kısmı.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap();

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(shareNavigatorProvider).handleColdStart();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(shareNavigatorProvider);
    return const KaydetApp();
  }
}
