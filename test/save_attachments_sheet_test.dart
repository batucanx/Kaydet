import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/device_downloads.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/mail_detail/save_attachments_sheet.dart';

AttachmentRow row(int id, String name, {int size = 2048}) => AttachmentRow(
  id: id,
  messageId: 1,
  partId: '$id',
  fileName: name,
  mimeType: 'application/octet-stream',
  sizeBytes: size,
  isInline: false,
  isOutgoing: false,
);

class RecordingDownloads extends DeviceDownloads {
  final List<String> saved = [];

  @override
  bool get canSaveDirectly => true;

  @override
  Future<DeviceSaveResult> save({
    required String sourcePath,
    required String fileName,
    String mimeType = '',
  }) async {
    saved.add(fileName);
    return const DeviceSaveResult(DeviceSaveOutcome.saved);
  }

  @override
  Future<void> notifySaved(List<SavedDeviceFile> files) async {}
}

void main() {
  final attachments = [
    row(1, 'LSN2026000008699.pdf', size: 113 * 1024),
    row(2, 'LSN2026000008699.xml', size: 344 * 1024),
  ];

  Future<void> openSheet(
    WidgetTester tester, {
    required RecordingDownloads downloads,
    List<AttachmentRow>? items,
    List<AttachmentRow>? resolved,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showSaveAttachmentsSheet(
                    context,
                    attachments: items ?? attachments,
                    downloads: downloads,
                    resolvePath: (a) async {
                      resolved?.add(a);
                      return Result.ok('/data/ekler/${a.id}/${a.fileName}');
                    },
                  ),
                  child: const Text('aç'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('aç'));
    await tester.pumpAndSettle();
  }

  List<bool?> checkboxValues(WidgetTester tester) => tester
      .widgetList<Checkbox>(find.byType(Checkbox))
      .map((c) => c.value)
      .toList();

  testWidgets('tüm ekler başta seçili listelenir (ad, boyut, hedef klasör)', (
    tester,
  ) async {
    await openSheet(tester, downloads: RecordingDownloads());

    expect(find.text('Ekleri kaydet'), findsOneWidget);
    expect(find.text('LSN2026000008699.pdf'), findsOneWidget);
    expect(find.text('LSN2026000008699.xml'), findsOneWidget);
    expect(find.text('113 KB'), findsOneWidget);
    expect(find.text('344 KB'), findsOneWidget);
    expect(find.textContaining('İndirilenler/Kaydet'), findsOneWidget);
    // [tümü, pdf, xml]
    expect(checkboxValues(tester), [true, true, true]);
    expect(find.text('Kaydet'), findsOneWidget);
  });

  testWidgets('seçimi kaldırılan ek kaydedilmez, kalan kaydedilir ve sayfa '
      'kapanır', (tester) async {
    final downloads = RecordingDownloads();
    final resolved = <AttachmentRow>[];
    await openSheet(tester, downloads: downloads, resolved: resolved);

    await tester.tap(find.text('LSN2026000008699.xml'));
    await tester.pump();
    // Tümünü-seç kutusu karışık (null) duruma geçer.
    expect(checkboxValues(tester), [null, true, false]);

    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(resolved.map((a) => a.id), [1]);
    expect(downloads.saved, ['LSN2026000008699.pdf']);
    // Sayfa kapandı ve sonuç bildirildi.
    expect(find.text('Ekleri kaydet'), findsNothing);
    expect(
      find.text('1 ek İndirilenler/Kaydet klasörüne kaydedildi.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('hiçbiri seçili değilken "Kaydet" devre dışıdır; Tümünü seç '
      'geri açar', (tester) async {
    final downloads = RecordingDownloads();
    await openSheet(tester, downloads: downloads);

    await tester.tap(find.text('Tümünü seç')); // hepsi seçili → hepsini kaldır
    await tester.pump();
    expect(checkboxValues(tester), [false, false, false]);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Kaydet'),
    );
    expect(button.onPressed, isNull);

    await tester.tap(find.text('Tümünü seç'));
    await tester.pump();
    expect(checkboxValues(tester), [true, true, true]);
    expect(downloads.saved, isEmpty);
  });

  testWidgets('tek ekli listede "Tümünü seç" satırı gösterilmez', (
    tester,
  ) async {
    await openSheet(
      tester,
      downloads: RecordingDownloads(),
      items: [attachments.first],
    );
    expect(find.text('Tümünü seç'), findsNothing);
    expect(checkboxValues(tester), [true]);
  });
}
