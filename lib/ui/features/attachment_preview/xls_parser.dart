import 'dart:typed_data';

import 'spreadsheet_viewer.dart' show SpreadsheetBook, SpreadsheetCell, SpreadsheetSheet;

/// Eski (ikili) Excel 97-2003 (.xls) biçimini okuyan bağımsız ayrıştırıcı.
///
/// .xls, bir "Compound File Binary" (OLE2) konteynerinin içinde "Workbook"
/// (çok eski BIFF5/7 dosyalarında "Book") adlı TEK bir akış (stream) olarak
/// saklanan BIFF8 kayıt dizisidir. İki katmanı vardır:
/// 1) CFB konteyner katmanı — sektörlere bölünmüş dosyadan adlı akışları
///    FAT/MiniFAT sektör zincirlerini izleyerek çıkarır (bkz. [_CfbFile]).
/// 2) BIFF8 kayıt katmanı — akışın baytlarını `[tür:u16][uzunluk:u16][veri]`
///    kayıtlarına ayırır; CONTINUE (0x003C) kayıtları önceki kaydın (özellikle
///    SST paylaşılan dize tablosunun) devamıdır (bkz. [_BiffWorkbookReader]).
///
/// Yalnızca ÖNİZLEME için gereken alt küme okunur: sayfa adları/sırası,
/// hücre metinleri (SST + eski LABEL/RSTRING) ve sayıları (NUMBER/RK/MULRK)
/// ile formül hücrelerinin dosyada zaten önbelleklenmiş sonucu. Formüller
/// yeniden hesaplanmaz — Excel'in dosyayı açar açmaz ekrana bastığı değer
/// zaten budur.
abstract final class XlsParser {
  static SpreadsheetBook parse(Uint8List bytes) {
    final cfb = _CfbFile(bytes);
    final workbookBytes =
        cfb.readStream('Workbook') ?? cfb.readStream('Book');
    if (workbookBytes == null) {
      throw const FormatException(
        'Workbook akışı bulunamadı (geçerli bir .xls dosyası değil).',
      );
    }
    return _BiffWorkbookReader(workbookBytes).read();
  }
}

// ============================================================ CFB (OLE2)

/// Microsoft Compound File Binary (OLE2) konteynerinden adlandırılmış
/// akışları (stream) çıkaran minimal, salt-okunur okuyucu. Yalnızca .xls
/// önizlemesi için gereken kadarı uygulanır: FAT + MiniFAT sektör zincirleri,
/// dizin (directory) girdileri ve ada göre akış arama.
class _CfbFile {
  factory _CfbFile(Uint8List bytes) {
    final file = _CfbFile._(bytes);
    file._readHeader();
    file._readFat();
    file._readDirectory();
    return file;
  }

  _CfbFile._(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;

  static const int _headerSize = 512;
  static const int _freeSect = 0xFFFFFFFF;
  static const int _endOfChain = 0xFFFFFFFE;
  static const int _difSect = 0xFFFFFFFC;

  late final int _sectorSize;
  late final int _miniSectorSize;
  late final int _miniStreamCutoff;
  late final int _firstDirSector;
  late final int _firstMiniFatSector;
  late final int _numMiniFatSectors;
  late final int _firstDifatSector;
  late final int _numDifatSectors;
  late final int _numFatSectors;

  late List<int> _fat;
  List<int>? _miniFat;
  Uint8List? _miniStream;

  final Map<String, ({int start, int size})> _streams = {};

  void _readHeader() {
    if (_bytes.length < _headerSize) {
      throw const FormatException('Dosya çok küçük (geçersiz OLE2 başlığı).');
    }
    final sectorShift = _data.getUint16(30, Endian.little);
    final miniSectorShift = _data.getUint16(32, Endian.little);
    // Gerçek dosyalarda sektör 512 ya da 4096 bayttır; başka bir değer bozuk
    // veriye işaret eder — kör bir 2^n hesaplaması dev bellek ayırmaya
    // (ör. shift=30 → 1GB "sektör") yol açabileceğinden erken reddedilir.
    if (sectorShift < 7 || sectorShift > 14 || miniSectorShift < 2 || miniSectorShift > sectorShift) {
      throw const FormatException('Desteklenmeyen OLE2 sektör boyutu.');
    }
    _sectorSize = 1 << sectorShift;
    _miniSectorSize = 1 << miniSectorShift;
    _numFatSectors = _data.getUint32(44, Endian.little);
    _firstDirSector = _data.getUint32(48, Endian.little);
    _miniStreamCutoff = _data.getUint32(56, Endian.little);
    _firstMiniFatSector = _data.getUint32(60, Endian.little);
    _numMiniFatSectors = _data.getUint32(64, Endian.little);
    _firstDifatSector = _data.getUint32(68, Endian.little);
    _numDifatSectors = _data.getUint32(72, Endian.little);
  }

  /// Sektör 0 her zaman dosyanın 512. baytında başlar — sektör boyutu 4096
  /// olsa BİLE başlık her zaman tam 512 bayttır (CFB belirtiminin sık
  /// karıştırılan bir ayrıntısı).
  Uint8List _sectorBytes(int sectorId, int sectorSize) {
    final offset = _headerSize + sectorId * sectorSize;
    if (sectorId < 0 || offset + sectorSize > _bytes.length) {
      throw const FormatException('Bozuk OLE2 sektör zinciri.');
    }
    return Uint8List.sublistView(_bytes, offset, offset + sectorSize);
  }

  void _readFat() {
    final fatSectorIds = <int>[];
    final maxFatSectors = _numFatSectors.clamp(0, 1 << 20);

    for (var i = 0; i < 109 && fatSectorIds.length < maxFatSectors; i++) {
      final id = _data.getUint32(76 + i * 4, Endian.little);
      if (id == _freeSect || id >= _difSect) break;
      fatSectorIds.add(id);
    }

    var difatSector = _firstDifatSector;
    var difatCount = 0;
    final maxDifatSectors = _numDifatSectors.clamp(0, 1 << 16);
    final visitedDifat = <int>{};
    while (difatSector != _endOfChain &&
        difatSector != _freeSect &&
        difatCount < maxDifatSectors &&
        fatSectorIds.length < maxFatSectors &&
        visitedDifat.add(difatSector)) {
      final sector = _sectorBytes(difatSector, _sectorSize);
      final sectorData = ByteData.sublistView(sector);
      final entriesPerSector = _sectorSize ~/ 4 - 1;
      for (var i = 0; i < entriesPerSector && fatSectorIds.length < maxFatSectors; i++) {
        final id = sectorData.getUint32(i * 4, Endian.little);
        if (id == _freeSect || id >= _difSect) break;
        fatSectorIds.add(id);
      }
      difatSector = sectorData.getUint32(entriesPerSector * 4, Endian.little);
      difatCount++;
    }

    final entriesPerFatSector = _sectorSize ~/ 4;
    _fat = List<int>.filled(fatSectorIds.length * entriesPerFatSector, _freeSect);
    for (var s = 0; s < fatSectorIds.length; s++) {
      final sectorData = ByteData.sublistView(_sectorBytes(fatSectorIds[s], _sectorSize));
      for (var i = 0; i < entriesPerFatSector; i++) {
        _fat[s * entriesPerFatSector + i] = sectorData.getUint32(i * 4, Endian.little);
      }
    }
  }

  /// [startSector]'dan başlayan normal FAT zincirini (döngü koruma ile) sonuna
  /// kadar okuyup birleştirir — toplam bayt sayısı önceden bilinmediğinde
  /// (dizin, MiniFAT tablosu) kullanılır.
  Uint8List _readWholeRegularChain(int startSector) {
    final chunks = <Uint8List>[];
    var sector = startSector;
    final visited = <int>{};
    while (sector != _endOfChain && sector != _freeSect && sector >= 0 && sector < _fat.length && visited.add(sector)) {
      chunks.add(_sectorBytes(sector, _sectorSize));
      sector = _fat[sector];
    }
    return _concat(chunks);
  }

  /// [startSector]'dan başlayıp tam [size] bayt döndüren normal FAT zinciri
  /// okuyucusu (akış boyutu dizin girdisinden zaten bilindiğinde kullanılır).
  Uint8List _readRegularChain(int startSector, int size) {
    if (size <= 0) return Uint8List(0);
    final result = Uint8List(size);
    var offset = 0;
    var sector = startSector;
    final visited = <int>{};
    while (offset < size && sector != _endOfChain && sector != _freeSect && sector >= 0 && sector < _fat.length && visited.add(sector)) {
      final data = _sectorBytes(sector, _sectorSize);
      final take = (size - offset).clamp(0, data.length);
      result.setRange(offset, offset + take, data, 0);
      offset += take;
      sector = _fat[sector];
    }
    return result;
  }

  Uint8List _readMiniChain(int startSector, int size) {
    final miniFat = _miniFat;
    final miniStream = _miniStream;
    if (size <= 0 || miniFat == null || miniStream == null) return Uint8List(0);
    final result = Uint8List(size);
    var offset = 0;
    var sector = startSector;
    final visited = <int>{};
    while (offset < size &&
        sector != _endOfChain &&
        sector != _freeSect &&
        sector >= 0 &&
        sector < miniFat.length &&
        visited.add(sector)) {
      final start = sector * _miniSectorSize;
      if (start + _miniSectorSize > miniStream.length) break;
      final take = (size - offset).clamp(0, _miniSectorSize);
      result.setRange(offset, offset + take, miniStream, start);
      offset += take;
      sector = miniFat[sector];
    }
    return result;
  }

  void _readDirectory() {
    final dirBytes = _readWholeRegularChain(_firstDirSector);
    final entryCount = dirBytes.length ~/ 128;

    int? rootStart;
    int? rootSize;

    for (var i = 0; i < entryCount; i++) {
      final base = i * 128;
      final entry = ByteData.sublistView(dirBytes, base, base + 128);
      final nameLenBytes = entry.getUint16(64, Endian.little);
      final objectType = entry.getUint8(66);
      if (objectType == 0) continue; // boş/kullanılmayan girdi
      if (nameLenBytes < 2 || nameLenBytes > 64) continue;

      final nameCharCount = (nameLenBytes ~/ 2) - 1;
      final nameBuffer = StringBuffer();
      for (var c = 0; c < nameCharCount; c++) {
        nameBuffer.writeCharCode(entry.getUint16(c * 2, Endian.little));
      }
      final name = nameBuffer.toString();

      final startSector = entry.getUint32(116, Endian.little);
      final size = entry.getUint32(120, Endian.little);

      if (objectType == 5) {
        rootStart = startSector;
        rootSize = size;
      } else if (objectType == 2) {
        _streams[name] = (start: startSector, size: size);
      }
    }

    if (rootStart != null && rootSize != null && rootSize > 0) {
      _miniStream = _readRegularChain(rootStart, rootSize);
    }

    if (_numMiniFatSectors > 0 && _firstMiniFatSector != _endOfChain && _firstMiniFatSector != _freeSect) {
      final miniFatBytes = _readWholeRegularChain(_firstMiniFatSector);
      final miniFatData = ByteData.sublistView(miniFatBytes);
      _miniFat = List<int>.generate(
        miniFatBytes.length ~/ 4,
        (i) => miniFatData.getUint32(i * 4, Endian.little),
      );
    }
  }

  /// [name] akışının tam içeriğini döner; akış yoksa `null`.
  Uint8List? readStream(String name) {
    final entry = _streams[name];
    if (entry == null) return null;
    if (entry.size <= 0) return Uint8List(0);
    if (entry.size >= _miniStreamCutoff || _miniFat == null || _miniStream == null) {
      return _readRegularChain(entry.start, entry.size);
    }
    return _readMiniChain(entry.start, entry.size);
  }

  static Uint8List _concat(List<Uint8List> chunks) {
    final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      result.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return result;
  }
}

// ============================================================== BIFF8

class _RawRecord {
  const _RawRecord(this.type, this.dataStart, this.length);
  final int type;
  final int dataStart;
  final int length;
}

/// Bir "genişletilmiş Unicode dize" okumasının sonucu: metin ve akıştaki bir
/// SONRAKİ kaydın indeksi (CONTINUE'lar tüketildiyse ilerlemiş olabilir).
class _StringRead {
  const _StringRead(this.text, this.nextIndex);
  final String text;
  final int nextIndex;
}

class _BiffWorkbookReader {
  _BiffWorkbookReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;

  static const int _rtBof = 0x0809;
  static const int _rtEof = 0x000A;
  static const int _rtBoundSheet = 0x0085;
  static const int _rtSst = 0x00FC;
  static const int _rtContinue = 0x003C;
  static const int _rtLabelSst = 0x00FD;
  static const int _rtLabel = 0x0204;
  static const int _rtRstring = 0x00D6;
  static const int _rtNumber = 0x0203;
  static const int _rtRk = 0x027E;
  static const int _rtMulRk = 0x00BD;
  static const int _rtFormula = 0x0006;
  static const int _rtStringResult = 0x0207;
  static const int _rtBoolErr = 0x0205;

  List<_RawRecord> _scanRecords() {
    final records = <_RawRecord>[];
    var pos = 0;
    while (pos + 4 <= _bytes.length) {
      final type = _data.getUint16(pos, Endian.little);
      final len = _data.getUint16(pos + 2, Endian.little);
      final dataStart = pos + 4;
      final dataEnd = dataStart + len;
      if (dataEnd > _bytes.length) break;
      records.add(_RawRecord(type, dataStart, len));
      pos = dataEnd;
    }
    return records;
  }

  SpreadsheetBook read() {
    final records = _scanRecords();
    if (records.isEmpty) {
      throw const FormatException('Workbook akışı boş ya da bozuk.');
    }

    final headerPosToIndex = <int, int>{
      for (var i = 0; i < records.length; i++) records[i].dataStart - 4: i,
    };

    // ---- 1) Globals alt akışı: ilk BOF ile ilk EOF arasında sayfa listesi
    // (BOUNDSHEET) ve paylaşılan dize tablosu (SST) bulunur.
    final sheetMetas = <({String name, int bofPosition})>[];
    var sharedStrings = const <String>[];

    var i = 0;
    if (records[i].type == _rtBof) i++;
    while (i < records.length && records[i].type != _rtEof) {
      final r = records[i];
      if (r.type == _rtBoundSheet) {
        sheetMetas.add(_readBoundSheet(r));
        i++;
      } else if (r.type == _rtSst) {
        final merged = _mergeContinues(records, i);
        sharedStrings = _readSst(merged.data);
        i = merged.nextIndex;
      } else {
        i++;
      }
    }

    // ---- 2) Her sayfa: BOUNDSHEET'teki lbPlyPos, o sayfanın BOF'unun akış
    // içindeki MUTLAK bayt konumudur.
    final sheets = <SpreadsheetSheet>[];
    for (final meta in sheetMetas) {
      final startIndex = headerPosToIndex[meta.bofPosition];
      if (startIndex == null) continue;
      sheets.add(_readSheet(meta.name, records, startIndex, sharedStrings));
    }

    if (sheets.isEmpty) {
      throw const FormatException('Çalışma kitabında sayfa bulunamadı.');
    }
    return SpreadsheetBook(sheets: sheets);
  }

  ({String name, int bofPosition}) _readBoundSheet(_RawRecord r) {
    final bofPosition = _data.getUint32(r.dataStart, Endian.little);
    // [lbPlyPos:u32][grbit:u16][cch:u8][flags:u8][karakterler] — kısa
    // biçim: sayfa adları zengin biçimlendirme/uzatılmış dize taşımaz.
    final cch = _data.getUint8(r.dataStart + 6);
    final flags = _data.getUint8(r.dataStart + 7);
    final compressed = flags & 0x01 == 0;
    final charStart = r.dataStart + 8;
    final name = _readFixedChars(charStart, cch, compressed, r.dataStart + r.length);
    return (name: name.isEmpty ? 'Sayfa' : name, bofPosition: bofPosition);
  }

  /// [count] karakteri (tek kayıt sınırları içinde, CONTINUE'a geçmeden)
  /// okur — BOUNDSHEET adları tek bir kayda sığacak kadar kısadır.
  String _readFixedChars(int start, int count, bool compressed, int limit) {
    final sb = StringBuffer();
    var pos = start;
    for (var c = 0; c < count; c++) {
      if (compressed) {
        if (pos + 1 > limit) break;
        sb.writeCharCode(_data.getUint8(pos));
        pos += 1;
      } else {
        if (pos + 2 > limit) break;
        sb.writeCharCode(_data.getUint16(pos, Endian.little));
        pos += 2;
      }
    }
    return sb.toString();
  }

  /// [recordIndex]'teki kaydı ve ondan HEMEN SONRA gelen tüm CONTINUE
  /// kayıtlarını tek bir bayt dizisinde birleştirir (yalnızca SST için
  /// gereklidir — diğer tüm kayıt türleri tek bir kayda sığar).
  ({Uint8List data, int nextIndex}) _mergeContinues(List<_RawRecord> records, int recordIndex) {
    final chunks = <Uint8List>[
      Uint8List.sublistView(_bytes, records[recordIndex].dataStart, records[recordIndex].dataStart + records[recordIndex].length),
    ];
    var next = recordIndex + 1;
    while (next < records.length && records[next].type == _rtContinue) {
      chunks.add(Uint8List.sublistView(_bytes, records[next].dataStart, records[next].dataStart + records[next].length));
      next++;
    }
    return (data: _CfbFile._concat(chunks), nextIndex: next);
  }

  /// SST kaydını (CONTINUE'larıyla birleştirilmiş hâliyle) çözer.
  ///
  /// Her paylaşılan dize [total:u32][unique:u32] başlığından SONRA ardışık
  /// olarak saklanır. Tek bir SST KAYDI birden çok BIFF kaydına (CONTINUE)
  /// yayılabildiği gibi, tek bir DİZE de aynı şekilde bir kayıt sınırını
  /// aşabilir — ancak burada zaten TÜM CONTINUE verisi tek bir düz arabelleğe
  /// birleştirildiğinden (bkz. [_mergeContinues]), asıl BIFF8 tuhaflığı olan
  /// "kayıt sınırında kırpılan dizenin devamında bayrak baytının tekrar
  /// gelmesi" kuralı burada ÖNEMSİZDİR: birleştirilmiş arabellek üzerinde
  /// dizeler normal şekilde art arda okunur.
  List<String> _readSst(Uint8List merged) {
    if (merged.length < 8) return const [];
    final data = ByteData.sublistView(merged);
    final unique = data.getUint32(4, Endian.little);
    final strings = <String>[];
    var pos = 8;
    for (var i = 0; i < unique && pos < merged.length; i++) {
      final read = _readRichExtString(merged, data, pos);
      strings.add(read.$1);
      pos = read.$2;
    }
    return strings;
  }

  /// `XLUnicodeRichExtendedString`i (SST/LABEL/RSTRING/STRING ortak biçimi)
  /// okur: `[cch:u16][grbit:u8][cRun:u16?][cbExtRst:u32?][karakterler]
  /// [rgRun: cRun*4 bayt]?[ExtRst: cbExtRst bayt]?`.
  (String, int) _readRichExtString(Uint8List buf, ByteData data, int pos) {
    if (pos + 3 > buf.length) return ('', buf.length);
    final cch = data.getUint16(pos, Endian.little);
    final flags = buf[pos + 2];
    final compressed = flags & 0x01 == 0;
    final hasRich = flags & 0x08 != 0;
    final hasExt = flags & 0x04 != 0;
    var cursor = pos + 3;

    var cRun = 0;
    if (hasRich) {
      if (cursor + 2 > buf.length) return ('', buf.length);
      cRun = data.getUint16(cursor, Endian.little);
      cursor += 2;
    }
    var cbExtRst = 0;
    if (hasExt) {
      if (cursor + 4 > buf.length) return ('', buf.length);
      cbExtRst = data.getUint32(cursor, Endian.little);
      cursor += 4;
    }

    // Bozuk/yanlış yorumlanmış bir bayrak baytı, gerçekçi olmayan dev
    // sayılar üretir — bu durumda sessizce devam ETMEK yerine, geri kalan
    // SST'yi (ve dolayısıyla sonraki tüm hücre metinlerini) bozmamak için
    // burada durulur.
    if (cch > 1 << 20 || cRun > 1 << 16 || cbExtRst > 1 << 24) {
      throw const FormatException('SST dizesi çözümlenemedi (beklenmeyen uzunluk).');
    }

    final sb = StringBuffer();
    for (var c = 0; c < cch; c++) {
      if (compressed) {
        if (cursor + 1 > buf.length) break;
        sb.writeCharCode(buf[cursor]);
        cursor += 1;
      } else {
        if (cursor + 2 > buf.length) break;
        sb.writeCharCode(data.getUint16(cursor, Endian.little));
        cursor += 2;
      }
    }

    cursor += cRun * 4;
    cursor += cbExtRst;
    return (sb.toString(), cursor.clamp(0, buf.length));
  }

  /// Tek bir kaydın verisi İÇİNDE (CONTINUE'a geçmeden) bir
  /// `XLUnicodeString` okur — LABEL/RSTRING/STRING kayıtları BÜYÜK metinler
  /// TAŞIMAZ, tek kayda sığar.
  _StringRead _readXlUnicodeStringInRecord(List<_RawRecord> records, int recordIndex, int byteOffset) {
    final r = records[recordIndex];
    final limit = r.dataStart + r.length;
    final merged = Uint8List.sublistView(_bytes, byteOffset, limit);
    final data = ByteData.sublistView(merged);
    final (text, _) = _readRichExtString(merged, data, 0);
    return _StringRead(text, recordIndex + 1);
  }

  SpreadsheetSheet _readSheet(
    String name,
    List<_RawRecord> records,
    int startIndex,
    List<String> sharedStrings,
  ) {
    final gridMap = <int, Map<int, SpreadsheetCell>>{};
    var maxCol = 0;
    var maxRow = 0;

    void setCell(int row, int col, String value, {bool isNumeric = false}) {
      if (value.isEmpty || row < 0 || col < 0) return;
      gridMap.putIfAbsent(row, () => {})[col] =
          SpreadsheetCell(value: value, isNumeric: isNumeric);
      if (col + 1 > maxCol) maxCol = col + 1;
      if (row + 1 > maxRow) maxRow = row + 1;
    }

    var i = startIndex;
    if (i < records.length && records[i].type == _rtBof) i++;

    int? pendingRow;
    int? pendingCol;

    while (i < records.length && records[i].type != _rtEof) {
      final r = records[i];
      switch (r.type) {
        case _rtLabelSst:
          final row = _data.getUint16(r.dataStart, Endian.little);
          final col = _data.getUint16(r.dataStart + 2, Endian.little);
          final isst = _data.getUint32(r.dataStart + 6, Endian.little);
          if (isst < sharedStrings.length) setCell(row, col, sharedStrings[isst]);
          i++;
          break;
        case _rtNumber:
          final row = _data.getUint16(r.dataStart, Endian.little);
          final col = _data.getUint16(r.dataStart + 2, Endian.little);
          final value = _data.getFloat64(r.dataStart + 6, Endian.little);
          setCell(row, col, _formatNumber(value), isNumeric: true);
          i++;
          break;
        case _rtRk:
          final row = _data.getUint16(r.dataStart, Endian.little);
          final col = _data.getUint16(r.dataStart + 2, Endian.little);
          final rk = _data.getUint32(r.dataStart + 6, Endian.little);
          setCell(row, col, _formatNumber(_decodeRk(rk)), isNumeric: true);
          i++;
          break;
        case _rtMulRk:
          final row = _data.getUint16(r.dataStart, Endian.little);
          final firstCol = _data.getUint16(r.dataStart + 2, Endian.little);
          final pairBytes = r.length - 2 - 2 - 2;
          final pairCount = pairBytes ~/ 6;
          for (var p = 0; p < pairCount; p++) {
            final base = r.dataStart + 4 + p * 6;
            final rk = _data.getUint32(base + 2, Endian.little);
            setCell(row, firstCol + p, _formatNumber(_decodeRk(rk)), isNumeric: true);
          }
          i++;
          break;
        case _rtLabel:
        case _rtRstring:
          {
            final row = _data.getUint16(r.dataStart, Endian.little);
            final col = _data.getUint16(r.dataStart + 2, Endian.little);
            final str = _readXlUnicodeStringInRecord(records, i, r.dataStart + 6);
            setCell(row, col, str.text);
            i = str.nextIndex;
            break;
          }
        case _rtFormula:
          {
            final row = _data.getUint16(r.dataStart, Endian.little);
            final col = _data.getUint16(r.dataStart + 2, Endian.little);
            final resultStart = r.dataStart + 6;
            final marker = _data.getUint16(resultStart + 6, Endian.little);
            if (marker == 0xFFFF) {
              final subType = _data.getUint8(resultStart);
              if (subType == 1) {
                setCell(row, col, _data.getUint8(resultStart + 2) != 0 ? 'DOĞRU' : 'YANLIŞ');
              } else if (subType == 2) {
                setCell(row, col, _formulaErrorText(_data.getUint8(resultStart + 2)));
              } else if (subType == 0) {
                pendingRow = row;
                pendingCol = col;
              }
            } else {
              setCell(row, col, _formatNumber(_data.getFloat64(resultStart, Endian.little)), isNumeric: true);
            }
            i++;
            break;
          }
        case _rtStringResult:
          if (pendingRow != null && pendingCol != null) {
            final str = _readXlUnicodeStringInRecord(records, i, r.dataStart);
            setCell(pendingRow, pendingCol, str.text);
            pendingRow = null;
            pendingCol = null;
            i = str.nextIndex;
          } else {
            i++;
          }
          break;
        case _rtBoolErr:
          {
            final row = _data.getUint16(r.dataStart, Endian.little);
            final col = _data.getUint16(r.dataStart + 2, Endian.little);
            final value = _data.getUint8(r.dataStart + 6);
            final isError = _data.getUint8(r.dataStart + 7) != 0;
            setCell(row, col, isError ? _formulaErrorText(value) : (value != 0 ? 'DOĞRU' : 'YANLIŞ'));
            i++;
            break;
          }
        default:
          i++;
      }
    }

    if (maxRow == 0 && maxCol == 0) {
      return SpreadsheetSheet(name: name, rows: const [], columnCount: 0);
    }
    final rows = <List<SpreadsheetCell>>[];
    for (var r = 0; r < maxRow; r++) {
      final rowMap = gridMap[r] ?? const <int, SpreadsheetCell>{};
      rows.add([
        for (var c = 0; c < maxCol; c++) rowMap[c] ?? const SpreadsheetCell(value: ''),
      ]);
    }
    return SpreadsheetSheet(name: name, rows: rows, columnCount: maxCol);
  }

  /// RK: sıkıştırılmış 32-bit sayı kodlaması (BIFF8 §2.5.198). Bit 0 (fX100)
  /// kümeliyse sonuç 100'e bölünür; bit 1 (fInt) kümeliyse üst 30 bit imzalı
  /// bir tam sayıdır, değilse bir IEEE754 double'ın üst 32 biti (alt 34 bit
  /// sıfır kabul edilir) olarak yorumlanır.
  static double _decodeRk(int rk) {
    final fX100 = rk & 0x01 != 0;
    final fInt = rk & 0x02 != 0;
    final top30 = rk >> 2;
    double value;
    if (fInt) {
      // 30 bitlik imzalı tam sayı: rk'yi önce imzalı 32-bit'e çevir (Dart
      // int'leri sonsuz hassasiyetlidir, taşma kendiliğinden olmaz), sonra
      // Dart'ın negatifte de işaret koruyan `>>`siyle 2 bit sağa kaydır.
      final signedRk = rk >= 0x80000000 ? rk - 0x100000000 : rk;
      value = (signedRk >> 2).toDouble();
    } else {
      final bits = ByteData(8);
      bits.setUint32(0, 0, Endian.little);
      bits.setUint32(4, (top30 << 2) & 0xFFFFFFFF, Endian.little);
      value = bits.getFloat64(0, Endian.little);
    }
    return fX100 ? value / 100.0 : value;
  }

  static String _formatNumber(double value) {
    if (value.isNaN || value.isInfinite) return '';
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    var text = value.toString();
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
    return text;
  }

  static String _formulaErrorText(int code) => switch (code) {
    0x00 => '#NULL!',
    0x07 => '#DIV/0!',
    0x0F => '#VALUE!',
    0x17 => '#REF!',
    0x1D => '#NAME?',
    0x24 => '#NUM!',
    0x2A => '#N/A',
    _ => '#HATA',
  };
}
