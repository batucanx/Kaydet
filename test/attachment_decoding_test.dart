import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

Uint8List ensureBinaryDecoded(Uint8List rawData) {
  if (rawData.isEmpty) return rawData;

  // If data already contains bytes > 127, it's definitely binary, not pure Base64 ASCII text.
  for (var i = 0; i < rawData.length; i++) {
    final b = rawData[i];
    if (b > 127) {
      return rawData; // Already binary data
    }
  }

  // All bytes are <= 127. Check if it's a valid Base64 string.
  try {
    final str = ascii.decode(rawData).replaceAll(RegExp(r'\s+'), '');
    if (str.length >= 4 && str.length % 4 == 0) {
      final base64Regex = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
      if (base64Regex.hasMatch(str)) {
        final decoded = base64.decode(str);
        if (decoded.isNotEmpty) {
          return decoded;
        }
      }
    }
  } catch (_) {
    // Decoding failed or not base64, return rawData
  }

  return rawData;
}

void main() {
  test('ensureBinaryDecoded correctly decodes Base64 ASCII to binary', () {
    // PNG Base64
    const pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final rawPngBytes = Uint8List.fromList(ascii.encode(pngBase64));

    final decodedPng = ensureBinaryDecoded(rawPngBytes);
    expect(decodedPng[0], 0x89);
    expect(decodedPng[1], 0x50); // P
    expect(decodedPng[2], 0x4E); // N
    expect(decodedPng[3], 0x47); // G

    // JPEG Base64 (/9j/...)
    const jpgBase64 = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';
    final rawJpgBytes = Uint8List.fromList(ascii.encode(jpgBase64));

    final decodedJpg = ensureBinaryDecoded(rawJpgBytes);
    expect(decodedJpg[0], 0xFF);
    expect(decodedJpg[1], 0xD8);
    expect(decodedJpg[2], 0xFF);

    // Already binary data (e.g. real PNG bytes starting with 0x89)
    final realPngHeader = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final resultPngHeader = ensureBinaryDecoded(realPngHeader);
    expect(resultPngHeader, equals(realPngHeader));
  });
}
