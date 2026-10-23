import 'dart:io';

import 'package:flutter/services.dart';

/// [DeviceDownloads.save] sonucu.
enum DeviceSaveOutcome {
  /// Dosya cihazın İndirilenler klasörüne yazıldı.
  saved,

  /// Bu platform/sürüm doğrudan kaydetmeyi desteklemiyor (iOS, Android 9 ve
  /// altı); çağıran taraf başka bir yönteme (diyalog, paylaşım) düşmelidir.
  unsupported,

  /// Destekleniyor ama bu dosya yazılamadı (depolama dolu, kaynak yok…).
  failed,
}

/// Dosyaları kullanıcıya diyalog göstermeden cihazın İndirilenler klasörüne
/// kaydeden yerel köprü (Android karşılığı: `DownloadsChannel.kt`).
///
/// Yalnızca Android 10+ destekler (`MediaStore.Downloads`: izin ve seçici
/// gerektirmez). Diğer durumlarda [DeviceSaveOutcome.unsupported] döner;
/// hiçbir yöntem istisna fırlatmaz (bkz. `result.dart`'taki kural).
class DeviceDownloads {
  const DeviceDownloads();

  static const MethodChannel _channel = MethodChannel(
    'tr.com.kaydetmail/downloads',
  );

  /// Dosyaların konulduğu alt klasör: `İndirilenler/Kaydet`. Diğer
  /// indirmelerle karışmasın, kullanıcı ekleri tek yerde bulsun.
  static const String folderName = 'Kaydet';

  /// Bu platformda doğrudan kaydetme DENENİR mi? (Android 9 ve altında yine de
  /// [DeviceSaveOutcome.unsupported] dönebilir.)
  bool get canSaveDirectly => Platform.isAndroid;

  Future<DeviceSaveResult> save({
    required String sourcePath,
    required String fileName,
    String mimeType = '',
  }) async {
    if (!canSaveDirectly) {
      return const DeviceSaveResult(DeviceSaveOutcome.unsupported);
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('saveToDownloads', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
        'folder': folderName,
      });
      if (raw is! Map) return const DeviceSaveResult(DeviceSaveOutcome.failed);
      final uri = raw['uri'];
      return DeviceSaveResult(
        DeviceSaveOutcome.saved,
        file: uri is String && uri.isNotEmpty
            ? SavedDeviceFile(
                uri: uri,
                name: raw['name'] is String ? raw['name'] as String : fileName,
                mimeType: raw['mimeType'] is String
                    ? raw['mimeType'] as String
                    : mimeType,
              )
            : null,
      );
    } on PlatformException catch (e) {
      return DeviceSaveResult(
        e.code == 'unsupported'
            ? DeviceSaveOutcome.unsupported
            : DeviceSaveOutcome.failed,
      );
    } on MissingPluginException {
      return const DeviceSaveResult(DeviceSaveOutcome.unsupported);
    } catch (_) {
      return const DeviceSaveResult(DeviceSaveOutcome.failed);
    }
  }

  /// Kaydedilen dosyalar için sistem "İndirme tamamlandı" bildirimi gösterir
  /// (tek dosya: dosyayı açar; çoklu: tek özet, klasörü açar).
  ///
  /// Bildirim izni kapalıysa hiçbir şey olmaz ve izin İSTENMEZ. Hiçbir hata
  /// dışarı sızmaz: bildirim kaydetmenin sonucunu etkilemez.
  Future<void> notifySaved(List<SavedDeviceFile> files) async {
    if (!canSaveDirectly || files.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('notifySaved', {
        'folder': folderName,
        'files': [
          for (final f in files)
            {'uri': f.uri, 'name': f.name, 'mimeType': f.mimeType},
        ],
      });
    } catch (_) {}
  }
}

/// [DeviceDownloads.save] ile `İndirilenler`e yazılmış bir dosya.
class SavedDeviceFile {
  const SavedDeviceFile({
    required this.uri,
    required this.name,
    this.mimeType = '',
  });

  /// `content://` adresi (bildirimden açmak için).
  final String uri;

  /// Sistemin verdiği GERÇEK ad (çakışmada `ad (1).pdf` olabilir).
  final String name;
  final String mimeType;
}

/// [DeviceDownloads.save] sonucu: [outcome] ve başarıda yazılan [file].
class DeviceSaveResult {
  const DeviceSaveResult(this.outcome, {this.file});

  final DeviceSaveOutcome outcome;
  final SavedDeviceFile? file;
}
