import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// İmza görseli için uzak URL doğrulama servisi (HTTPS, zararlı karakter
/// koruması, erişilebilirlik).
abstract final class SignatureImageService {
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
}
