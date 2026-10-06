import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/use_cases/sieve_block.dart';

/// Sunucu filtre için kullanılamaz (ManageSieve yok, STARTTLS/PLAIN yok, `fileinto` yok, giriş
/// reddedildi…). Hata değil, bir yetenek cevabıdır.
class SieveUnavailable implements Exception {
  const SieveUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'SieveUnavailable($reason)';
}

/// Sunucu, çalışması gereken bir komuta `NO`/`BYE` dedi.
class SieveCommandFailed implements Exception {
  const SieveCommandFailed(this.what);
  final String what;
  @override
  String toString() => 'SieveCommandFailed($what)';
}

/// [ManageSieveService.apply] sonucu.
enum SenderFilterOutcome {
  /// Sunucunun filtresi artık listeyle aynı.
  applied,

  /// Zaten aynıydı.
  unchanged,

  /// Bu sunucu bu yolla filtrelenemiyor; hiçbir şeye dokunulmadı.
  unsupported,
}

/// Kaydet'in oluşturduğu betik (kullanıcının etkin betiği yoksa).
const String kaydetScriptName = 'kaydet';

/// Kaydet bir betiği ilk kez değiştirmeden önce, kullanıcının betiğinin bir kopyası.
const String kaydetBackupName = 'kaydet-backup';

/// Soket katmanı: protokol, soketsiz test edilebilsin diye enjekte edilir.
abstract class SieveTransport {
  Future<void> write(List<int> data);

  /// Sunucunun gönderdiği sonraki parça; bağlantı kapanırsa/zaman aşımında hata fırlatır.
  Future<Uint8List> read();

  /// TLS'e yükseltir (sunucu `STARTTLS`i kabul ettikten sonra).
  Future<void> startTls();

  void close();
}

class _Line {
  const _Line(this.tokens);
  final List<String> tokens;
}

class _Parsed {
  const _Parsed(this.line, this.next);
  final _Line line;
  final int next;
}

class SieveResponse {
  const SieveResponse(this.status, this.message, this.lines);
  final String status; // OK | NO | BYE
  final String message;
  final List<List<String>> lines;
}

/// Bir yanıt satırını ayrıştırır; literal henüz tamamlanmadıysa `null` döner.
_Parsed? _parseLine(Uint8List buf, int start) {
  final tokens = <String>[];
  var i = start;
  for (;;) {
    while (i < buf.length && buf[i] == 0x20) {
      i++;
    }
    if (i >= buf.length) return null;
    final ch = buf[i];
    if (ch == 0x0d) {
      if (i + 1 >= buf.length) return null;
      return _Parsed(_Line(tokens), i + 2);
    }
    if (ch == 0x22) {
      final bytes = <int>[];
      i++;
      for (;;) {
        if (i >= buf.length) return null;
        final c = buf[i];
        if (c == 0x5c) {
          if (i + 1 >= buf.length) return null;
          bytes.add(buf[i + 1]);
          i += 2;
        } else if (c == 0x22) {
          i++;
          break;
        } else {
          bytes.add(c);
          i++;
        }
      }
      tokens.add(utf8.decode(bytes, allowMalformed: true));
    } else if (ch == 0x7b) {
      var close = i + 1;
      while (close < buf.length && buf[close] != 0x7d) {
        close++;
      }
      if (close >= buf.length) return null;
      final size = int.tryParse(
        latin1.decode(buf.sublist(i + 1, close)).replaceAll('+', ''),
      );
      if (size == null || size < 0 || size > 1048576) {
        throw const SieveCommandFailed('geçersiz literal boyutu');
      }
      final dataStart = close + 3; // '}' CR LF
      if (buf.length < dataStart + size) return null;
      tokens.add(
        utf8.decode(buf.sublist(dataStart, dataStart + size), allowMalformed: true),
      );
      i = dataStart + size;
    } else {
      var j = i;
      while (j < buf.length && buf[j] != 0x20 && buf[j] != 0x0d) {
        j++;
      }
      if (j >= buf.length) return null;
      tokens.add(latin1.decode(buf.sublist(i, j)));
      i = j;
    }
  }
}

String _q(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// ManageSieve (RFC 5804) oturumu: yalnızca Kaydet'in ihtiyacı olan komutlar.
///
/// Güvenlik: parola yalnızca STARTTLS başarılı olduktan SONRA gönderilir ([authenticate] aksi
/// hâlde reddeder), asla loglanmaz ve hata iletileri protokol metni taşımaz.
class SieveSession {
  SieveSession(this._transport);

  final SieveTransport _transport;
  Uint8List _buffer = Uint8List(0);
  bool _tls = false;
  Map<String, String> capabilities = {};

  Future<SieveResponse> _nextResponse() async {
    final lines = <List<String>>[];
    var pos = 0;
    for (;;) {
      final parsed = _parseLine(_buffer, pos);
      if (parsed == null) {
        _buffer = Uint8List.sublistView(_buffer, pos);
        pos = 0;
        final more = await _transport.read();
        _buffer = Uint8List.fromList([..._buffer, ...more]);
        continue;
      }
      pos = parsed.next;
      final tokens = parsed.line.tokens;
      final first = tokens.isEmpty ? '' : tokens.first.toUpperCase();
      if (first == 'OK' || first == 'NO' || first == 'BYE') {
        _buffer = Uint8List.sublistView(_buffer, pos);
        final rest = [
          for (final t in tokens.skip(1))
            if (!t.startsWith('(')) t,
        ];
        return SieveResponse(first, rest.isEmpty ? '' : rest.last, lines);
      }
      lines.add(tokens);
    }
  }

  Future<SieveResponse> _send(String command) async {
    await _transport.write(utf8.encode('$command\r\n'));
    return _nextResponse();
  }

  static SieveResponse _ok(SieveResponse r, String what) {
    if (r.status != 'OK') throw SieveCommandFailed(what);
    return r;
  }

  void _readCapabilities(SieveResponse r) {
    capabilities = {
      for (final l in r.lines)
        if (l.isNotEmpty) l.first.toUpperCase(): l.length > 1 ? l[1] : '',
    };
  }

  /// Selamlamayı okur.
  Future<void> open() async {
    final greeting = await _nextResponse();
    if (greeting.status != 'OK') throw const SieveUnavailable('selamlama reddedildi');
    _readCapabilities(greeting);
  }

  /// TLS'e yükseltir; STARTTLS'siz sunucu kullanılamaz (parola asla açık gönderilmez).
  Future<void> startTls() async {
    if (!capabilities.containsKey('STARTTLS')) {
      throw const SieveUnavailable('STARTTLS yok');
    }
    final answer = await _send('STARTTLS');
    if (answer.status != 'OK') throw const SieveUnavailable('STARTTLS reddedildi');
    await _transport.startTls();
    _tls = true;
    _buffer = Uint8List(0);
    final caps = await _nextResponse(); // el sıkışmadan sonra yetenekler yeniden gelir
    if (caps.status != 'OK') throw const SieveUnavailable('TLS sonrası yetenek yok');
    _readCapabilities(caps);
  }

  bool supports(String extension) => (capabilities['SIEVE'] ?? '')
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .contains(extension.toLowerCase());

  /// Yalnızca TLS üzerinden SASL PLAIN.
  Future<void> authenticate(String username, String password) async {
    if (!_tls) throw const SieveUnavailable('TLS olmadan kimlik doğrulanmaz');
    final mechanisms = (capabilities['SASL'] ?? '').toUpperCase().split(RegExp(r'\s+'));
    if (!mechanisms.contains('PLAIN')) throw const SieveUnavailable('PLAIN yok');
    final initial = base64.encode(utf8.encode('\u0000$username\u0000$password'));
    final answer = await _send('AUTHENTICATE "PLAIN" "$initial"');
    if (answer.status != 'OK') throw const SieveUnavailable('giriş reddedildi');
  }

  Future<List<({String name, bool active})>> listScripts() async {
    final answer = _ok(await _send('LISTSCRIPTS'), 'LISTSCRIPTS');
    return [
      for (final l in answer.lines)
        if (l.isNotEmpty)
          (
            name: l.first,
            active: l.skip(1).any((t) => t.toUpperCase() == 'ACTIVE'),
          ),
    ];
  }

  Future<String> getScript(String name) async {
    final answer = _ok(await _send('GETSCRIPT ${_q(name)}'), 'GETSCRIPT');
    return answer.lines.isEmpty || answer.lines.first.isEmpty
        ? ''
        : answer.lines.first.first;
  }

  /// Sunucu betiği saklamadan derler.
  Future<void> checkScript(String content) async {
    final bytes = utf8.encode(content).length;
    await _transport.write(utf8.encode('CHECKSCRIPT {$bytes+}\r\n$content\r\n'));
    _ok(await _nextResponse(), 'CHECKSCRIPT');
  }

  Future<void> putScript(String name, String content) async {
    final bytes = utf8.encode(content).length;
    await _transport.write(
      utf8.encode('PUTSCRIPT ${_q(name)} {$bytes+}\r\n$content\r\n'),
    );
    _ok(await _nextResponse(), 'PUTSCRIPT');
  }

  Future<void> setActive(String name) async {
    _ok(await _send('SETACTIVE ${_q(name)}'), 'SETACTIVE');
  }

  Future<void> logout() async {
    try {
      await _send('LOGOUT');
    } on Object {
      // bağlantı zaten kapanıyor
    }
    _transport.close();
  }
}

/// Gerçek soket: TCP, istenince TLS.
class SocketSieveTransport implements SieveTransport {
  SocketSieveTransport._(this._socket, this._host, this._timeout) {
    _attach(_socket);
  }

  static Future<SocketSieveTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return SocketSieveTransport._(socket, host, timeout);
  }

  Socket _socket;
  final String _host;
  final Duration _timeout;
  StreamSubscription<Uint8List>? _sub;
  final List<Uint8List> _queue = [];
  Completer<Uint8List>? _waiting;
  Object? _failure;

  void _attach(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        final w = _waiting;
        if (w != null) {
          _waiting = null;
          w.complete(chunk);
        } else {
          _queue.add(chunk);
        }
      },
      onError: (Object _) => _fail(const SieveUnavailable('bağlantı hatası')),
      onDone: () => _fail(const SieveUnavailable('bağlantı kapandı')),
      cancelOnError: true,
    );
  }

  void _fail(Object error) {
    _failure = error;
    final w = _waiting;
    if (w != null) {
      _waiting = null;
      w.completeError(error);
    }
  }

  @override
  Future<void> write(List<int> data) async {
    try {
      _socket.add(data);
      await _socket.flush();
    } on Object {
      throw const SieveUnavailable('yazma hatası');
    }
  }

  @override
  Future<Uint8List> read() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final failure = _failure;
    if (failure != null) return Future.error(failure);
    final completer = Completer<Uint8List>();
    _waiting = completer;
    return completer.future.timeout(
      _timeout,
      onTimeout: () => throw const SieveUnavailable('zaman aşımı'),
    );
  }

  @override
  Future<void> startTls() async {
    try {
      await _sub?.cancel();
      _sub = null;
      _socket = await SecureSocket.secure(_socket, host: _host);
      _attach(_socket);
    } on Object {
      throw const SieveUnavailable('TLS el sıkışması başarısız');
    }
  }

  @override
  void close() {
    unawaited(_sub?.cancel());
    _socket.destroy();
  }
}

/// Posta sunucusundaki Sieve betiğinde engellenen göndericiler kuralını tutar (IMAP sunucusunda
/// ManageSieve). Web sunucusundaki `ManageSieveAdapter` ile aynı kurallar:
///
/// - ManageSieve/STARTTLS/PLAIN/`fileinto` yoksa `unsupported`: hiçbir şeye dokunulmaz,
///   istemcinin kendi Gelen Kutusu taraması zaten çalışır.
/// - Kullanıcının betiği DEĞİŞTİRİLİR, ezilmez: yalnızca Kaydet'in işaretli bloğu değişir; sonuç
///   sunucuda derlendikten (`CHECKSCRIPT`) sonra, ve orijinalin bir yedeği bir kez saklanır.
/// - Değişmeyen blok yeniden yazılmaz.
class ManageSieveService {
  ManageSieveService({
    this.port = 4190,
    Future<SieveTransport> Function(String host, int port)? openTransport,
  }) : _open = openTransport ?? ((host, port) => SocketSieveTransport.connect(host, port));

  final int port;
  final Future<SieveTransport> Function(String host, int port) _open;

  Future<SenderFilterOutcome> apply({
    required String host,
    required String username,
    required String password,
    required Iterable<String> emails,
    required String junkMailbox,
  }) async {
    SieveSession? session;
    try {
      session = SieveSession(await _open(host, port));
      await session.open();
      await session.startTls();
      await session.authenticate(username, password);
      if (!session.supports('fileinto')) return SenderFilterOutcome.unsupported;
      return await _applyOn(session, emails, junkMailbox);
    } on SieveUnavailable {
      return SenderFilterOutcome.unsupported;
    } on SocketException {
      return SenderFilterOutcome.unsupported;
    } on TimeoutException {
      return SenderFilterOutcome.unsupported;
    } finally {
      await session?.logout();
    }
  }

  Future<SenderFilterOutcome> _applyOn(
    SieveSession session,
    Iterable<String> emails,
    String junkMailbox,
  ) async {
    final list = normalizeBlockedEmails(emails);
    final scripts = await session.listScripts();
    final active = scripts.where((s) => s.active).firstOrNull;

    if (active == null) {
      if (list.isEmpty) return SenderFilterOutcome.unchanged;
      final script = applyBlockedSendersBlock('', list, junkMailbox);
      await session.checkScript(script);
      final name = scripts.any((s) => s.name == kaydetScriptName)
          ? '$kaydetScriptName-${DateTime.now().millisecondsSinceEpoch}'
          : kaydetScriptName;
      await session.putScript(name, script);
      await session.setActive(name);
      return SenderFilterOutcome.applied;
    }

    final current = await session.getScript(active.name);
    final next = applyBlockedSendersBlock(current, list, junkMailbox);
    if (next == current) return SenderFilterOutcome.unchanged;

    await session.checkScript(next);
    // Bir kez, ilk değişiklikten önce: kullanıcının betiği olduğu gibi.
    if (!scripts.any((s) => s.name == kaydetBackupName) &&
        readBlockedSendersBlock(current) == null) {
      await session.putScript(kaydetBackupName, current);
    }
    await session.putScript(active.name, next); // etkin betiği yerinde değiştirir, etkin kalır
    return SenderFilterOutcome.applied;
  }
}
