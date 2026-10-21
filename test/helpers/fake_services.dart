import 'dart:async';
import 'dart:typed_data';

import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/services/imap_service.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';

/// Sahte IMAP sunucusu.
///
/// Gerçek protokol davranışını taklit eder: klasörler, UID'ler, bayraklar,
/// taşıma ve kalıcı silme. Böylece arayüz testleri gerçek akışı izler.
class FakeImapService implements ImapService {
  FakeImapService({this.failOnConnect});

  /// Ayarlanırsa `connect` bu hatayla döner (giriş hatası senaryoları).
  AppFailure? failOnConnect;

  /// Ayarlanırsa `moveMessages` bu hatayla döner (taşıma başarısızlığı).
  AppFailure? failMove;

  /// Ayarlanırsa `fetchFlags` bu hatayla döner (bayrak eşitleme hatası).
  AppFailure? failFlags;

  /// Ayarlanırsa `appendMessage` bu hatayla döner (Gönderilenler yazma hatası).
  AppFailure? failAppend;

  /// `fetchBody`/`fetchAttachment` yanıt vermeden önce beklenen süre; iki
  /// işlemin sıralanıp sıralanmadığını sınamak için.
  Duration bodyDelay = Duration.zero;

  bool _connected = false;
  String? selectedPath;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// path → UID → zarf
  final Map<String, Map<int, FetchedEnvelope>> store = {};

  /// path → UID → gövde
  final Map<String, Map<int, FetchedBody>> bodies = {};

  final List<RemoteMailbox> mailboxes = [
    const RemoteMailbox(
      path: 'INBOX',
      name: 'INBOX',
      delimiter: '.',
      specialUse: SpecialUse.inbox,
    ),
    const RemoteMailbox(
      path: 'INBOX.Sent',
      name: 'Sent',
      delimiter: '.',
      specialUse: SpecialUse.sent,
    ),
    const RemoteMailbox(
      path: 'INBOX.Drafts',
      name: 'Drafts',
      delimiter: '.',
      specialUse: SpecialUse.drafts,
    ),
    const RemoteMailbox(
      path: 'INBOX.Trash',
      name: 'Trash',
      delimiter: '.',
      specialUse: SpecialUse.trash,
    ),
    const RemoteMailbox(
      path: 'INBOX.Junk',
      name: 'Junk',
      delimiter: '.',
      specialUse: SpecialUse.junk,
    ),
    const RemoteMailbox(
      path: 'INBOX.Archive',
      name: 'Archive',
      delimiter: '.',
      specialUse: SpecialUse.archive,
    ),
  ];

  /// `moveMessages`'a giden kodlanmış (modified UTF-7) kaynak/hedef yollar.
  final List<({String? source, String? target})> moveEncodedPaths = [];

  int uidValidity = 1000;
  final List<String> commandLog = [];

  /// Kullanıcının iletilerine yönelik kalıcı silmeler. Arka plandaki ayar
  /// eşitlemesi `Kaydet-Settings` klasöründeki eski ayar belgesini de siler;
  /// o, ileti silme davranışının testlerini ilgilendirmez.
  Iterable<String> get messageExpunges => commandLog.where(
    (c) => c.startsWith('expunge:') && !c.contains('Kaydet-Settings'),
  );

  /// Teste hazır bir gelen kutusu doldurur.
  void seedInbox(List<FetchedEnvelope> envelopes) {
    final box = store.putIfAbsent('INBOX', () => {});
    for (final envelope in envelopes) {
      box[envelope.uid] = envelope;
    }
  }

  void seedBody(String path, int uid, FetchedBody body) {
    bodies.putIfAbsent(path, () => {})[uid] = body;
  }

  Map<int, FetchedEnvelope> _box(String path) =>
      store.putIfAbsent(path, () => {});

  @override
  bool get isConnected => _connected;

  @override
  Stream<void> get serverChanges => _changes.stream;

  @override
  Future<Result<ServerCapabilities>> connect(MailServerConfig config) async {
    commandLog.add('connect:${config.host}:${config.port}');
    final failure = failOnConnect;
    if (failure != null) return Err(failure);
    _connected = true;
    return const Ok(
      ServerCapabilities(
        raw: ['IMAP4rev1', 'IDLE', 'MOVE', 'UIDPLUS'],
        supportsIdle: true,
        supportsMove: true,
        supportsCondStore: false,
        supportsQresync: false,
        supportsUidPlus: true,
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    selectedPath = null;
  }

  /// Gerçek servis gibi canlı oturuma (`_connected`, `selectedPath`) dokunmaz.
  @override
  Future<Result<void>> verify(MailServerConfig config) async {
    commandLog.add('verify:${config.host}:${config.port}');
    final failure = failOnConnect;
    if (failure != null) return Err(failure);
    return okVoid;
  }

  @override
  Future<Result<List<RemoteMailbox>>> listMailboxes() async {
    commandLog.add('list');
    return Ok(mailboxes);
  }

  @override
  Future<Result<MailboxState>> statusMailbox(
    String path, {
    String? encodedPath,
    bool includeUnseen = false,
  }) async {
    commandLog.add('status:$path');
    final box = _box(path);
    final maxUid = box.keys.isEmpty
        ? 0
        : box.keys.reduce((a, b) => a > b ? a : b);
    // Gerçek `STATUS (UNSEEN)` gibi `\Deleted` işaretli iletileri de sayar.
    final unseen = box.values.where((e) => !e.flags.contains(r'\Seen')).length;
    return Ok(
      MailboxState(
        uidValidity: uidValidity,
        uidNext: maxUid + 1,
        messageCount: box.length,
        unseenCount: includeUnseen ? unseen : null,
      ),
    );
  }

  /// Ayarlanırsa `countUnseen` bu hatayla döner.
  AppFailure? failCountUnseen;

  @override
  Future<Result<int>> countUnseen({
    required String path,
    String? encodedPath,
  }) async {
    commandLog.add('countUnseen:$path');
    final failure = failCountUnseen;
    if (failure != null) return Err(failure);
    return Ok(
      _box(path).values
          .where(
            (e) =>
                !e.flags.contains(r'\Seen') && !e.flags.contains(r'\Deleted'),
          )
          .length,
    );
  }

  @override
  Future<Result<MailboxState>> selectMailbox(
    String path, {
    String? encodedPath,
    bool enableCondStore = false,
  }) async {
    commandLog.add('select:$path');
    selectedPath = path;
    final box = _box(path);
    final maxUid = box.keys.isEmpty
        ? 0
        : box.keys.reduce((a, b) => a > b ? a : b);
    return Ok(
      MailboxState(
        uidValidity: uidValidity,
        uidNext: maxUid + 1,
        messageCount: box.length,
        permanentFlags: [r'\Seen', r'\Flagged', r'\*'],
      ),
    );
  }

  @override
  Future<Result<List<int>>> searchAllUids() async {
    commandLog.add('search');
    final box = _box(selectedPath ?? 'INBOX');
    return Ok(box.keys.toList()..sort());
  }

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopes(List<int> uids) async {
    commandLog.add('fetch:${uids.length}');
    final box = _box(selectedPath ?? 'INBOX');
    return Ok([
      for (final uid in uids)
        if (box[uid] != null) box[uid]!,
    ]);
  }

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeRange({
    required int fromUid,
    required int toUid,
  }) async {
    final box = _box(selectedPath ?? 'INBOX');
    return Ok([
      for (final entry in box.entries)
        if (entry.key >= fromUid && entry.key <= toUid) entry.value,
    ]);
  }

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeSequenceRange({
    required int fromSeq,
    required int toSeq,
  }) async {
    commandLog.add('fetchSeq:$fromSeq:$toSeq');
    final box = _box(selectedPath ?? 'INBOX');
    final sortedEntries = box.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    if (sortedEntries.isEmpty || toSeq < fromSeq || fromSeq < 1) {
      return const Ok(<FetchedEnvelope>[]);
    }
    final startIdx = (fromSeq - 1).clamp(0, sortedEntries.length);
    final endIdx = toSeq.clamp(0, sortedEntries.length);
    if (startIdx >= endIdx) return const Ok(<FetchedEnvelope>[]);
    return Ok([
      for (var i = startIdx; i < endIdx; i++) sortedEntries[i].value,
    ]);
  }

  @override
  Future<Result<List<int>>> searchUidsInSet(List<int> uids) async {
    commandLog.add('search');
    final box = _box(selectedPath ?? 'INBOX');
    return Ok(uids.where((u) => box.containsKey(u)).toList());
  }

  @override
  Future<Result<int?>> searchSequenceByUid(int uid) async {
    commandLog.add('searchSeqByUid:$uid');
    final box = _box(selectedPath ?? 'INBOX');
    final sortedKeys = box.keys.toList()..sort();
    final idx = sortedKeys.indexOf(uid);
    return Ok(idx >= 0 ? idx + 1 : null);
  }

  @override
  Future<Result<List<RemoteFlagState>>> fetchFlags(
    List<int> uids, {
    int? changedSinceModSeq,
  }) async {
    commandLog.add('flags:${uids.length}');
    final failure = failFlags;
    if (failure != null) return Err(failure);
    final box = _box(selectedPath ?? 'INBOX');
    return Ok([
      for (final uid in uids)
        if (box[uid] != null)
          RemoteFlagState(uid: uid, flags: box[uid]!.flags),
    ]);
  }

  @override
  Future<Result<FetchedBody>> fetchBody(int uid) async {
    final path = selectedPath ?? 'INBOX';
    commandLog.add('body:$path:$uid');
    if (bodyDelay > Duration.zero) await Future<void>.delayed(bodyDelay);
    return Ok(bodies[path]?[uid] ?? const FetchedBody(plainText: ''));
  }

  @override
  Future<Result<Uint8List>> fetchAttachment(int uid, String partId) async =>
      Ok(Uint8List.fromList([1, 2, 3]));

  @override
  Future<Result<void>> storeFlags({
    required List<int> uids,
    required List<String> flags,
    required bool add,
  }) async {
    commandLog.add('store:${flags.join(",")}:${add ? "+" : "-"}:$uids');
    final box = _box(selectedPath ?? 'INBOX');
    for (final uid in uids) {
      final envelope = box[uid];
      if (envelope == null) continue;
      final next = [...envelope.flags];
      for (final flag in flags) {
        if (add) {
          if (!next.contains(flag)) next.add(flag);
        } else {
          next.remove(flag);
        }
      }
      box[uid] = _copyWithFlags(envelope, next);
    }
    return okVoid;
  }

  @override
  Future<Result<void>> moveMessages({
    required List<int> uids,
    required String targetPath,
    String? sourcePath,
    String? sourceEncodedPath,
    String? targetEncodedPath,
  }) async {
    if (sourcePath != null) selectedPath = sourcePath;
    moveEncodedPaths.add((source: sourceEncodedPath, target: targetEncodedPath));
    commandLog.add('move:$selectedPath->$targetPath:$uids');
    final failure = failMove;
    if (failure != null) return Err(failure);
    final source = _box(selectedPath ?? 'INBOX');
    final target = _box(targetPath);
    final nextUid = target.keys.isEmpty
        ? 1
        : target.keys.reduce((a, b) => a > b ? a : b) + 1;
    var offset = 0;
    for (final uid in uids) {
      final envelope = source.remove(uid);
      if (envelope == null) continue;
      target[nextUid + offset] = envelope;
      offset++;
    }
    return okVoid;
  }

  @override
  Future<Result<void>> deletePermanently(List<int> uids) async {
    commandLog.add('expunge:${selectedPath ?? 'INBOX'}:$uids');
    final box = _box(selectedPath ?? 'INBOX');
    for (final uid in uids) {
      box.remove(uid);
    }
    return okVoid;
  }

  @override
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    String? encodedPath,
    List<String> flags = const [],
  }) async {
    commandLog.add('append:$targetPath');
    final appendFailure = failAppend;
    if (appendFailure != null) return Err(appendFailure);
    final box = _box(targetPath);
    final uid =
        box.keys.isEmpty ? 1 : box.keys.reduce((a, b) => a > b ? a : b) + 1;
    var subject = 'Eklenen ileti';
    String? messageId;
    final subjectMatch = RegExp(r'^Subject:\s*(.*?)$', multiLine: true, caseSensitive: false).firstMatch(mimeSource);
    if (subjectMatch != null && subjectMatch.group(1)!.trim().isNotEmpty) {
      subject = subjectMatch.group(1)!.trim();
    }
    final msgIdMatch = RegExp(r'^Message-ID:\s*(.*?)$', multiLine: true, caseSensitive: false).firstMatch(mimeSource);
    if (msgIdMatch != null && msgIdMatch.group(1)!.trim().isNotEmpty) {
      messageId = msgIdMatch.group(1)!.trim();
    }
    box[uid] = FetchedEnvelope(
      uid: uid,
      date: DateTime.now().toUtc(),
      subject: subject,
      from: null,
      to: const [],
      cc: const [],
      bcc: const [],
      flags: flags,
      sizeBytes: mimeSource.length,
      hasAttachments: false,
      messageId: messageId,
    );
    return Ok(uid);
  }

  /// path → UID → ham ileti kaynağı (`fetchRawSource`, iade iletisi testleri).
  final Map<String, Map<int, String>> rawSources = {};

  @override
  Future<Result<String>> fetchRawSource(int uid, {int maxChars = 200000}) async {
    commandLog.add('raw:${selectedPath ?? 'INBOX'}:$uid');
    final source = rawSources[selectedPath ?? 'INBOX']?[uid];
    if (source == null) return const Err(MessageNotFoundFailure());
    return Ok(source);
  }

  /// Ayarlanırsa `existsByMessageId` bu hatayla döner (doğrulama başarısızlığı).
  AppFailure? failExistsByMessageId;

  @override
  Future<Result<bool>> existsByMessageId({
    required String path,
    String? encodedPath,
    required String messageId,
  }) async {
    commandLog.add('exists:$path');
    final failure = failExistsByMessageId;
    if (failure != null) return Err(failure);
    String bare(String? id) => (id ?? '').trim().replaceAll(RegExp(r'^<|>$'), '');
    final wanted = bare(messageId);
    final found = _box(path).values.any((e) => bare(e.messageId) == wanted);
    return Ok(found);
  }

  /// `unsubscribe:` komutlarının yolları (ayar klasörünü gizleme testleri için).
  final List<String> unsubscribed = [];

  @override
  Future<Result<void>> unsubscribeMailbox(String encodedPath) async {
    commandLog.add('unsubscribe:$encodedPath');
    unsubscribed.add(encodedPath);
    return okVoid;
  }

  @override
  Future<Result<void>> createMailbox(String path) async {
    commandLog.add('create:$path');
    mailboxes.add(
      RemoteMailbox(
        path: path,
        name: path.split('.').last,
        delimiter: '.',
        specialUse: SpecialUse.custom,
      ),
    );
    return okVoid;
  }

  @override
  Future<Result<void>> deleteMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
  }) async {
    commandLog.add('delete:$path');
    mailboxes.removeWhere((m) => m.path == path);
    store.remove(path);
    bodies.remove(path);
    return okVoid;
  }

  @override
  Future<Result<void>> renameMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
    required String newPath,
  }) async {
    commandLog.add('rename:$path->$newPath');
    final index = mailboxes.indexWhere((m) => m.path == path);
    if (index != -1) {
      final old = mailboxes[index];
      mailboxes[index] = RemoteMailbox(
        path: newPath,
        name: newPath.split(delimiter).last,
        delimiter: delimiter,
        specialUse: old.specialUse,
        encodedPath: old.encodedPath,
        isSelectable: old.isSelectable,
        isSubscribed: old.isSubscribed,
      );
    }
    final movedMessages = store.remove(path);
    if (movedMessages != null) store[newPath] = movedMessages;
    final movedBodies = bodies.remove(path);
    if (movedBodies != null) bodies[newPath] = movedBodies;
    if (selectedPath == path) selectedPath = newPath;
    return okVoid;
  }

  @override
  Future<Result<void>> noop({Duration? timeout}) async {
    commandLog.add('noop');
    return okVoid;
  }

  bool _idling = false;

  @override
  bool get isIdling => _idling;

  @override
  Future<Result<void>> startIdle() async {
    _idling = true;
    return okVoid;
  }

  @override
  Future<Result<void>> stopIdle() async {
    _idling = false;
    return okVoid;
  }

  /// Sunucudan yeni ileti geldiğini bildirir (IDLE benzetimi).
  void notifyChange() => _changes.add(null);

  Future<void> dispose() async => _changes.close();

  static FetchedEnvelope _copyWithFlags(
    FetchedEnvelope source,
    List<String> flags,
  ) =>
      FetchedEnvelope(
        uid: source.uid,
        date: source.date,
        subject: source.subject,
        from: source.from,
        to: source.to,
        cc: source.cc,
        bcc: source.bcc,
        flags: flags,
        sizeBytes: source.sizeBytes,
        hasAttachments: source.hasAttachments,
        messageId: source.messageId,
        inReplyTo: source.inReplyTo,
        references: source.references,
        preview: source.preview,
      );
}

/// Sahte SMTP sunucusu.
class FakeSmtpService implements SmtpService {
  AppFailure? failOnSend;
  AppFailure? failOnVerify;
  final List<OutgoingMessage> sent = [];

  @override
  Future<Result<SentMessage>> send({
    required MailServerConfig config,
    required OutgoingMessage message,
  }) async {
    final failure = failOnSend;
    if (failure != null) return Err(failure);
    sent.add(message);
    final messageId = 'gonderildi-${sent.length}@test';
    return Ok(
      SentMessage(
        messageId: messageId,
        mimeSource:
            'Message-ID: <$messageId>\r\n'
            'Subject: ${message.subject}\r\n\r\n${message.plainText}',
        serverReply: '250 2.0.0 OK queued as FAKE${sent.length}',
      ),
    );
  }

  @override
  Future<Result<void>> verify(MailServerConfig config) async {
    final failure = failOnVerify;
    if (failure != null) return Err(failure);
    return okVoid;
  }
}

/// Test için hızlı zarf üretici.
FetchedEnvelope envelope({
  required int uid,
  String subject = 'Test konusu',
  String fromName = 'Ahmet Yılmaz',
  String fromEmail = 'ahmet@musteri.com',
  bool seen = false,
  bool flagged = false,
  DateTime? date,
  List<String>? extraFlags,
  String? messageId,
  String? references,
}) =>
    FetchedEnvelope(
      uid: uid,
      date: date ?? DateTime.utc(2026, 9, 14, 10, 30),
      subject: subject,
      from: EmailAddress(email: fromEmail, name: fromName),
      to: const [EmailAddress(email: 'info@pazarlik.com.tr')],
      cc: const [],
      bcc: const [],
      flags: [
        if (seen) r'\Seen',
        if (flagged) r'\Flagged',
        ...?extraFlags,
      ],
      sizeBytes: 2048,
      hasAttachments: false,
      messageId: messageId ?? 'msg-$uid@test',
      references: references,
    );
