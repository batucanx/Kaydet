import 'dart:async';
import 'dart:typed_data';

import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/tables.dart';
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

  int uidValidity = 1000;
  final List<String> commandLog = [];

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

  @override
  Future<Result<List<RemoteMailbox>>> listMailboxes() async {
    commandLog.add('list');
    return Ok(mailboxes);
  }

  @override
  Future<Result<MailboxState>> selectMailbox(
    String path, {
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
  Future<Result<List<RemoteFlagState>>> fetchFlags(
    List<int> uids, {
    int? changedSinceModSeq,
  }) async {
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
  }) async {
    commandLog.add('move:$selectedPath->$targetPath:$uids');
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
    commandLog.add('expunge:$uids');
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
    List<String> flags = const [],
  }) async {
    commandLog.add('append:$targetPath');
    final box = _box(targetPath);
    final uid =
        box.keys.isEmpty ? 1 : box.keys.reduce((a, b) => a > b ? a : b) + 1;
    box[uid] = FetchedEnvelope(
      uid: uid,
      date: DateTime.now().toUtc(),
      subject: 'Eklenen ileti',
      from: null,
      to: const [],
      cc: const [],
      bcc: const [],
      flags: flags,
      sizeBytes: mimeSource.length,
      hasAttachments: false,
    );
    return Ok(uid);
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
  Future<Result<void>> noop() async => okVoid;

  @override
  Future<Result<void>> startIdle() async => okVoid;

  @override
  Future<Result<void>> stopIdle() async => okVoid;

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
    return Ok(
      SentMessage(
        messageId: 'gonderildi-${sent.length}@test',
        mimeSource: 'Subject: ${message.subject}\r\n\r\n${message.plainText}',
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
