import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachment_files.dart';

/// Yazma ekranından eklenen dosyaların kalıcı deposu.
///
/// Galeri/kamera/dosya seçicileri dosyayı işletim sisteminin GEÇİCİ (önbellek)
/// klasörüne kopyalar; sistem depolama azaldığında ya da uygulama kapalıyken
/// burayı istediği an temizleyebilir. Taslaklar haftalarca bekleyebildiği için
/// bu yola güvenilirse gönderim anında dosya yoktur. Bu yüzden eklenen her
/// dosya, ekleme anında uygulamanın kendi kalıcı klasörüne kopyalanır
/// (`<uygulama>/giden_ekler/<kimlik>/<ad>`).
///
/// Bu kopyalar hiçbir taslağa/kuyruktaki iletiye bağlı olmadığında [sweep]
/// tarafından silinir.
class OutgoingAttachmentStore {
  OutgoingAttachmentStore({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  static const String directoryName = 'giden_ekler';

  final Future<Directory> Function() _rootProvider;

  static Future<Directory> _defaultRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, directoryName));
  }

  /// [sourcePath]'i kalıcı klasöre kopyalar ve YENİ yolu döner. Dosya zaten bu
  /// klasördeyse (ör. taslaktan yeniden açılan ek) aynen döner.
  Future<String> persist(String sourcePath) async {
    final root = await _rootProvider();
    if (p.isWithin(root.path, sourcePath)) return sourcePath;

    // Her ek kendi klasöründe: aynı adlı iki dosya birbirinin üstüne yazılmaz.
    // `createTemp` benzersizliği işletim sistemi garanti eder (saat tabanlı bir
    // ad, düşük çözünürlüklü saatlerde iki eki aynı klasöre düşürebilirdi).
    await root.create(recursive: true);
    final folder = await root.createTemp('ek_');
    final target = File(
      p.join(folder.path, AttachmentFiles.safeFileName(p.basename(sourcePath))),
    );
    try {
      await File(sourcePath).copy(target.path);
    } on FileSystemException {
      // Yarım kalmış kopya ve boş klasör bırakılmaz.
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // Silinemediyse bir sonraki süpürmede toplanır.
      }
      rethrow;
    }
    return target.path;
  }

  /// [activePaths]'te OLMAYAN ve [grace]'ten eski kopyaları siler. Dönüş:
  /// silinen klasör sayısı.
  ///
  /// [activePaths] hâlâ gerekli olan dosyalardır (bkz.
  /// `AppDatabase.activeOutgoingAttachmentPaths`: taslaklar, gönderilmeyi
  /// bekleyen/başarısız iletiler). [grace] henüz taslağa yazılmamış, ekranda
  /// açık bir yazma ekranındaki dosyaların süpürülmesini imkânsız kılacak
  /// kadar geniştir.
  Future<int> sweep({
    required Set<String> activePaths,
    Duration grace = const Duration(hours: 24),
    DateTime? now,
  }) async {
    final root = await _rootProvider();
    if (!await root.exists()) return 0;

    final reference = now ?? DateTime.now();
    var removed = 0;
    // Önce liste alınır: dizin dolaşılırken silmek platforma göre atlanan ya da
    // hata veren girdilere yol açabilir.
    final entities = await root.list(followLinks: false).toList();
    for (final entity in entities) {
      if (entity is! Directory) continue;
      if (activePaths.any((path) => p.isWithin(entity.path, path))) continue;
      try {
        final age = reference.difference((await entity.stat()).modified);
        if (age <= grace) continue;
        await entity.delete(recursive: true);
        removed++;
      } on FileSystemException {
        // Kilitli/erişilemiyor; bir sonraki süpürmede yeniden denenir.
      }
    }
    return removed;
  }
}
