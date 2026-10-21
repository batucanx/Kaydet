import 'dart:ui' show Rect;

import 'package:file_saver/file_saver.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../data/services/device_downloads.dart';

/// Cihaza kaydedilmeye hazır (indirilmiş) tek bir ek.
class BatchSaveFile {
  const BatchSaveFile({
    required this.path,
    required this.fileName,
    required this.mimeType,
  });

  final String path;
  final String fileName;
  final String mimeType;
}

/// Toplu kaydetmenin hangi yoldan yapıldığı.
enum BatchSaveMode {
  /// Android 10+: seçici açılmadan doğrudan `İndirilenler/Kaydet`e yazıldı.
  folder,

  /// Android 9 ve altı: dosya başına sistem "kaydet" diyaloğu.
  picker,

  /// iOS ve diğerleri: tüm dosyalar tek paylaşım sayfasında sunuldu
  /// ("Dosyalara Kaydet" oradan seçilir).
  share,
}

/// [saveAttachmentsToDevice]'ın sonucu.
class BatchSaveReport {
  const BatchSaveReport({
    this.saved = 0,
    this.failed = 0,
    this.mode = BatchSaveMode.folder,
    this.firstFailure,
  });

  /// Cihaza yazılan (ya da paylaşım sayfasına sunulan) ek sayısı.
  final int saved;

  /// İndirilemeyen ya da yazılamayan ek sayısı. Kullanıcının seçiciyi
  /// kapatması hata SAYILMAZ.
  final int failed;

  final BatchSaveMode mode;

  /// İndirme aşamasındaki ilk hata — hepsi başarısızsa kullanıcıya nedeni
  /// (bağlantı yok, ileti silinmiş…) söyleyebilmek için.
  final AppFailure? firstFailure;

  /// Kullanıcıya gösterilecek özet; gösterilecek bir şey yoksa `null`
  /// (ör. paylaşım sayfası kendi arayüzüyle sonucu zaten bildirir, ya da
  /// kullanıcı seçiciyi hiç kaydetmeden kapattı).
  String? get message {
    if (failed == 0) {
      if (saved == 0 || mode == BatchSaveMode.share) return null;
      return mode == BatchSaveMode.folder
          ? '$saved ek İndirilenler/${DeviceDownloads.folderName} '
                'klasörüne kaydedildi.'
          : '$saved ek kaydedildi.';
    }
    if (saved > 0) return '$saved ek kaydedildi, $failed ek kaydedilemedi.';
    return firstFailure?.userMessage ??
        (failed == 1 ? 'Ek kaydedilemedi.' : 'Ekler kaydedilemedi.');
  }
}

/// Seçicili kayıt: `true` kaydedildi, `false` kullanıcı vazgeçti; hata
/// istisna olarak fırlar.
typedef SaveAsFn = Future<bool> Function(BatchSaveFile file);

/// Tüm dosyaları tek paylaşım sayfasında sunar.
typedef ShareFilesFn =
    Future<void> Function(List<BatchSaveFile> files, Rect? origin);

/// [attachments]'ı sırayla indirir (gerekirse) ve cihaza kaydeder.
///
/// İndirmeler SIRAYLA yapılır: IMAP bağlantısı hesap başına tektir
/// (`MailConnection.exclusive`), paralel istek yalnızca sıraya girerdi.
/// Bir ekin indirilememesi diğerlerini DURDURMAZ; sayısı rapora yansır.
///
/// Kaydetme yolu platforma göre seçilir (bkz. [BatchSaveMode]):
/// Android 10+ → doğrudan klasör; Android 9 ve altı → dosya başına seçici;
/// diğer platformlar → tek paylaşım sayfası. [saveAs] ve [share] yalnızca
/// testlerde değiştirilir.
Future<BatchSaveReport> saveAttachmentsToDevice({
  required List<AttachmentRow> attachments,
  required Future<Result<String>> Function(AttachmentRow attachment)
  resolvePath,
  DeviceDownloads downloads = const DeviceDownloads(),
  Rect? shareOrigin,
  void Function(int done, int total)? onProgress,
  SaveAsFn? saveAs,
  ShareFilesFn? share,
}) async {
  final total = attachments.length;
  onProgress?.call(0, total);

  final ready = <BatchSaveFile>[];
  var downloadFailures = 0;
  AppFailure? firstFailure;
  for (var i = 0; i < total; i++) {
    final attachment = attachments[i];
    Result<String> result;
    try {
      result = await resolvePath(attachment);
    } catch (e) {
      result = Result.err(UnknownFailure(detail: '$e'));
    }
    final path = result.valueOrNull;
    if (path == null) {
      downloadFailures++;
      firstFailure ??= result.failureOrNull;
    } else {
      ready.add(
        BatchSaveFile(
          path: path,
          fileName: attachment.fileName,
          mimeType: attachment.mimeType,
        ),
      );
    }
    onProgress?.call(i + 1, total);
  }

  if (ready.isEmpty) {
    return BatchSaveReport(
      failed: downloadFailures,
      firstFailure: firstFailure,
    );
  }

  if (!downloads.canSaveDirectly) {
    try {
      await (share ?? _shareFiles)(ready, shareOrigin);
      return BatchSaveReport(
        saved: ready.length,
        failed: downloadFailures,
        mode: BatchSaveMode.share,
        firstFailure: firstFailure,
      );
    } catch (_) {
      return BatchSaveReport(
        failed: downloadFailures + ready.length,
        mode: BatchSaveMode.share,
        firstFailure: firstFailure,
      );
    }
  }

  var saved = 0;
  var failed = downloadFailures;
  var mode = BatchSaveMode.folder;
  final written = <SavedDeviceFile>[];
  for (final file in ready) {
    if (mode == BatchSaveMode.folder) {
      final result = await downloads.save(
        sourcePath: file.path,
        fileName: file.fileName,
        mimeType: file.mimeType,
      );
      final outcome = result.outcome;
      if (outcome == DeviceSaveOutcome.saved) {
        saved++;
        final writtenFile = result.file;
        if (writtenFile != null) written.add(writtenFile);
        continue;
      }
      if (outcome == DeviceSaveOutcome.failed) {
        failed++;
        continue;
      }
      // Bu cihazda doğrudan kaydetme yok (Android 9 ve altı): kalan dosyalar
      // için seçiciye düşülür.
      mode = BatchSaveMode.picker;
    }
    try {
      if (await (saveAs ?? _saveAs)(file)) {
        saved++;
      } else {
        // Kullanıcı seçiciyi kapattı: kalan dosyalar için tekrar tekrar
        // sormak yerine toplu kaydı bırakmış sayılır.
        break;
      }
    } catch (_) {
      failed++;
    }
  }
  // Doğrudan klasöre yazılanlar için TEK özet bildirim (izin kapalıysa
  // gösterilmez; hata saymaz).
  if (written.isNotEmpty) await downloads.notifySaved(written);
  return BatchSaveReport(
    saved: saved,
    failed: failed,
    mode: mode,
    firstFailure: firstFailure,
  );
}

Future<bool> _saveAs(BatchSaveFile file) async {
  final ext = p.extension(file.fileName);
  final saved = await FileSaver.instance.saveAs(
    name: p.basenameWithoutExtension(file.fileName),
    filePath: file.path,
    fileExtension: ext.startsWith('.') ? ext.substring(1) : ext,
    mimeType: MimeType.other,
  );
  return saved != null;
}

Future<void> _shareFiles(List<BatchSaveFile> files, Rect? origin) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        for (final f in files)
          XFile(f.path, mimeType: f.mimeType, name: f.fileName),
      ],
      sharePositionOrigin: origin,
    ),
  );
}
