import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/core/theme/tokens.dart';
import 'package:kaydet/ui/features/mail_list/mail_row.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/test_db.dart';

/// Gönderilenler satırındaki sunucu onayı rozeti.
void main() {
  late AppDatabase db;
  late MessageRow base;
  late AppSettingsStore settingsStore;

  Future<void> pumpRow(
    WidgetTester tester, {
    required MessageRow message,
    bool isSentFolder = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(settingsStore),
          ownEmailDomainsProvider.overrideWithValue(<String>{}),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MailRow(
              message: message,
              labels: const [],
              isSelected: false,
              isSentFolder: isSentFolder,
              onTap: () {},
              onAvatarTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ),
    );
  }

  Future<void> createBase(WidgetTester tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      settingsStore = await AppSettingsStore.create();
      db = createTestDatabase();
      final accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'info@pazarlik.com.tr',
          username: 'info@pazarlik.com.tr',
          imapHost: 'mail.pazarlik.com.tr',
          smtpHost: 'mail.pazarlik.com.tr',
        ),
      );
      final sentId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX.Sent',
          name: 'Gönderilenler',
          specialUse: const Value(SpecialUse.sent),
        ),
      );
      await db.upsertServerMessages([
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: sentId,
          dateUtc: DateTime.utc(2026, 9, 14, 10, 30),
          uid: const Value(1),
          subject: const Value('Teklif'),
        ),
      ]);
      base = (await db.messageByUid(sentId, 1))!;
    });
  }

  tearDown(() async {
    await db.close();
  });

  testWidgets('SMTP kabulü: "Gönderildi"; başarı/doğrulandı iması yok', (
    tester,
  ) async {
    await createBase(tester);
    await pumpRow(
      tester,
      message: base.copyWith(
        outboxState: OutboxState.sent,
        smtpAcceptedAt: Value(DateTime.utc(2026, 9, 14, 10, 31)),
        // Gönderilenler kopyası doğrulanmış olsa bile rozet teslim iddia etmez.
        sentVerifiedAt: Value(DateTime.utc(2026, 9, 14, 10, 32)),
      ),
    );
    expect(find.text('Gönderildi'), findsOneWidget);
    expect(find.textContaining('doğrula'), findsNothing);
    expect(_planeColor(tester), KaydetTokens.light.textTertiary);
  });

  testWidgets('iade iletisi gelmişse kırmızı "Teslim edilemedi" ve neden', (
    tester,
  ) async {
    await createBase(tester);
    await pumpRow(
      tester,
      message: base.copyWith(
        outboxState: OutboxState.sent,
        smtpAcceptedAt: Value(DateTime.utc(2026, 9, 14, 10, 31)),
        deliveryFailedAt: Value(DateTime.utc(2026, 9, 14, 10, 33)),
        deliveryFailureReason: const Value(
          'yok@firma.com: Alıcı adresi bulunamadı',
        ),
      ),
    );
    expect(
      find.text('Teslim edilemedi: yok@firma.com: Alıcı adresi bulunamadı'),
      findsOneWidget,
    );
    expect(find.text('Gönderildi'), findsNothing);
    final text = tester.widget<Text>(find.textContaining('Teslim edilemedi'));
    expect(text.style?.color, KaydetTokens.light.danger);
  });

  testWidgets('sunucudan eşitlenen satırda (kabul bilgisi yok) rozet çıkmaz', (
    tester,
  ) async {
    await createBase(tester);
    await pumpRow(
      tester,
      message: base.copyWith(outboxState: OutboxState.sent),
    );
    expect(find.text('Gönderildi'), findsNothing);
    expect(find.textContaining('Teslim edilemedi'), findsNothing);
  });

  testWidgets('Gönderilenler dışındaki listede rozet çıkmaz', (tester) async {
    await createBase(tester);
    await pumpRow(
      tester,
      isSentFolder: false,
      message: base.copyWith(
        outboxState: OutboxState.sent,
        smtpAcceptedAt: Value(DateTime.utc(2026, 9, 14, 10, 31)),
      ),
    );
    expect(find.text('Gönderildi'), findsNothing);
  });
}

/// Rozetteki kâğıt uçağı (`send.png`) simgesinin boyama rengi.
Color? _planeColor(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .where((i) => (i.image as AssetImage).assetName == 'assets/icons/send.png')
    .single
    .color;
