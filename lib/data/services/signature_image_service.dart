import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// İmza görselinin boyut modu (küçük, orta, büyük).
enum SignatureImageSize {
  small(120, 'Küçük'),
  medium(200, 'Orta'),
  large(320, 'Büyük');

  const SignatureImageSize(this.targetWidth, this.label);

  final int targetWidth;
  final String label;

  static SignatureImageSize fromWidth(int width) {
    if (width <= 140) return SignatureImageSize.small;
    if (width >= 280) return SignatureImageSize.large;
    return SignatureImageSize.medium;
  }
}

/// Görselin metne göre konumu.
enum SignatureImagePosition {
  top('top', 'Metnin üstünde'),
  bottom('bottom', 'Metnin altında');

  const SignatureImagePosition(this.value, this.label);

  final String value;
  final String label;

  static SignatureImagePosition fromValue(String? val) {
    if (val == 'top') return SignatureImagePosition.top;
    return SignatureImagePosition.bottom;
  }
}

/// Görsel imza yönetim servisi:
/// - Galeriden seçilen görselleri optimize eder (aşırı büyük pikselleri küçültür,
///   dosya boyutunu sıkıştırır).
/// - İmzayı kalıcı `app_flutter/signatures/` dizinine kopyalar.
/// - Uzak URL'leri doğrular (HTTPS, zararlı karakter koruması, erişilebilirlik).
abstract final class SignatureImageService {
  static const int maxDimension = 800; // max width/height for local signature
  static const int maxFileSize = 3 * 1024 * 1024; // 3MB local limit

  /// İmzaların saklandığı yerel dizin.
  static Future<Directory> getSignatureStorageDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'signatures'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Galeriden veya dosya seçiciden gelen görseli optimize edip
  /// kalıcı imza dizinine kaydeder.
  static Future<String> processAndSaveLocalImage({
    required String sourcePath,
    required int accountId,
  }) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw const FileSystemException('Görsel dosyası bulunamadı');
    }

    final ext = p.extension(sourcePath).toLowerCase();
    final allowedExts = {'.png', '.jpg', '.jpeg', '.webp'};
    if (!allowedExts.contains(ext)) {
      throw const FormatException('Yalnızca PNG, JPG veya WebP desteklenir');
    }

    final bytes = await file.readAsBytes();
    if (bytes.length > maxFileSize * 2) {
      throw const FormatException('Görsel boyutu çok büyük (maks 6MB)');
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Görsel çözümlenemedi veya bozuk');
    }

    // Aspect ratio korunarak gerekirse küçültülür
    img.Image processed = decoded;
    if (decoded.width > maxDimension || decoded.height > maxDimension) {
      processed = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? maxDimension : null,
        height: decoded.height > decoded.width ? maxDimension : null,
        interpolation: img.Interpolation.cubic,
      );
    }

    final targetDir = await getSignatureStorageDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    // Saydamlık korunması için PNG veya JPEG
    final bool hasAlpha = processed.hasAlpha;
    final targetExt = hasAlpha ? '.png' : '.jpg';
    final targetPath = p.join(
      targetDir.path,
      'sig_${accountId}_$timestamp$targetExt',
    );

    final Uint8List encodedBytes;
    if (hasAlpha) {
      encodedBytes = Uint8List.fromList(img.encodePng(processed, level: 6));
    } else {
      encodedBytes = Uint8List.fromList(img.encodeJpg(processed, quality: 85));
    }

    final targetFile = File(targetPath);
    await targetFile.writeAsBytes(encodedBytes, flush: true);
    return targetPath;
  }

  /// Uzak görsel URL'sinin formatını (HTTP/HTTPS ve zararlı karakter kontrolü) doğrular.
  static bool isValidImageUrlFormat(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return false;
    if (trimmed.contains('<') ||
        trimmed.contains('>') ||
        trimmed.contains('"') ||
        trimmed.contains("'") ||
        trimmed.contains(r'\')) {
      return false;
    }
    return true;
  }

  /// Uzak görsel URL'sini doğrular ve erişilebilirliğini test eder.
  /// Hata durumunda null döner veya hata mesajı üretir.
  static Future<({bool isValid, String? error})> validateRemoteImageUrl(
    String url,
  ) async {
    final trimmed = url.trim();
    if (!isValidImageUrlFormat(trimmed)) {
      return (
        isValid: false,
        error: 'Geçerli bir HTTP veya HTTPS görsel URL\'si giriniz',
      );
    }

    final uri = Uri.parse(trimmed);

    // Güvenlik: script, data, javascript, html injection engelleme
    if (trimmed.contains('<') ||
        trimmed.contains('>') ||
        trimmed.contains('"') ||
        trimmed.contains("'") ||
        trimmed.contains(r'\')) {
      return (isValid: false, error: 'URL zararlı karakter içeremez');
    }

    // Uzak görselin varlığını ve MIME tipini kontrol et (HEAD veya GET)
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 3;
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          isValid: false,
          error: 'Görsele erişilemedi (HTTP ${response.statusCode})',
        );
      }

      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      // Bazı sunucular generic octet-stream dönebilir, uzantı resimse de kabul et
      final ext = p.extension(uri.path).toLowerCase();
      final hasImageExt = {'.png', '.jpg', '.jpeg', '.webp', '.gif'}.contains(
        ext,
      );

      if (contentType != null && !contentType.startsWith('image/')) {
        if (!hasImageExt) {
          return (
            isValid: false,
            error: 'URL bir görsel dosyası göstermiyor ($contentType)',
          );
        }
      }

      return (isValid: true, error: null);
    } on SocketException {
      return (isValid: false, error: 'Sunucuya bağlanılamadı');
    } on HandshakeException {
      return (isValid: false, error: 'Güvenli bağlantı kurulamadı (SSL hatası)');
    } on TimeoutException {
      return (isValid: false, error: 'Bağlantı zaman aşımına uğradı');
    } catch (e) {
      return (isValid: false, error: 'Görsel doğrulanamadı: $e');
    } finally {
      client.close();
    }
  }

  /// Eski imza görselini temizler (artık kullanılmıyorsa).
  static Future<void> deleteLocalSignatureFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Hata sessizce yutulur
    }
  }
}
