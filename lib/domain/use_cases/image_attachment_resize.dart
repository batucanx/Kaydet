import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// "Resim boyutunu küçült" seçilince uygulanan hedef: gerçek Outlook/Gmail'in
/// varsayılan küçültmesiyle aynı büyüklük sınıfı — en uzun kenar 1600px,
/// JPEG kalite 85. Tipik bir telefon fotoğrafını (ör. 4000x3000, birkaç MB)
/// çoğunlukla birkaç yüz KB'a indirir.
const int _maxDimension = 1600;
const int _jpegQuality = 85;

/// [source] JPEG/PNG görselini e-posta eki için küçültüp geçici bir dosyaya
/// yazar, yeni dosyanın yolunu döner.
///
/// Görsel zaten [_maxDimension] sınırının altındaysa veya çözülemezse
/// (bozuk dosya) [source] olduğu gibi döner — küçültme "iyi olsun" bir
/// adımdır, ekin gönderilmesini engellemez. Diğer görsel biçimleri (GIF,
/// HEIC/HEIF, WEBP, BMP) bilerek dokunulmadan bırakılır: GIF'te animasyon,
/// HEIC'te decoder desteği riske girer.
Future<File> resizeImageAttachment(File source) async {
  final extension = p.extension(source.path).toLowerCase();
  if (extension != '.jpg' && extension != '.jpeg' && extension != '.png') {
    return source;
  }

  final Uint8List bytes;
  try {
    bytes = await source.readAsBytes();
  } on FileSystemException {
    return source;
  }

  final resizedBytes = await compute(
    _resizeBytes,
    _ResizeRequest(bytes, extension),
  );
  if (resizedBytes == null) return source;

  final dir = await getTemporaryDirectory();
  final outFile = File(
    p.join(
      dir.path,
      'kaydet_resized_${DateTime.now().microsecondsSinceEpoch}_${p.basename(source.path)}',
    ),
  );
  await outFile.writeAsBytes(resizedBytes, flush: true);
  return outFile;
}

class _ResizeRequest {
  const _ResizeRequest(this.bytes, this.extension);

  final Uint8List bytes;
  final String extension;
}

/// `compute` ile ayrı bir isolate'ta çalışır: decode + resize + encode
/// büyük görsellerde onlarca-yüzlerce ms sürebilir, ana isolate'ı (ve
/// arayüzü) bloklamaması gerekir.
Uint8List? _resizeBytes(_ResizeRequest request) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) return null;
  if (decoded.width <= _maxDimension && decoded.height <= _maxDimension) {
    return null;
  }

  final resized = img.copyResize(
    decoded,
    width: decoded.width >= decoded.height ? _maxDimension : null,
    height: decoded.height > decoded.width ? _maxDimension : null,
    interpolation: img.Interpolation.average,
  );

  return request.extension == '.png'
      ? img.encodePng(resized)
      : img.encodeJpg(resized, quality: _jpegQuality);
}
