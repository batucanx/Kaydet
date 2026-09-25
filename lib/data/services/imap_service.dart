import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:synchronized/synchronized.dart';

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';

/// IMAP işlemlerinin sözleşmesi.
///
/// `enough_mail` yalnızca bu dosyanın altındaki uygulamada geçer. Paket
/// değişirse yeniden yazılacak tek yer burasıdır.
abstract class ImapService {
  /// Sunucuya bağlanır ve oturum açar.
  Future<Result<ServerCapabilities>> connect(MailServerConfig config);

  Future<void> disconnect();

  bool get isConnected;

  /// Tüm klasörleri listeler.
  Future<Result<List<RemoteMailbox>>> listMailboxes();

  /// Klasörü seçer ve durumunu döner.
  Future<Result<MailboxState>> selectMailbox(
    String path, {
    bool enableCondStore = false,
  });

  /// Klasördeki tüm UID'leri döner (silinenleri tespit etmek için).
  Future<Result<List<int>>> searchAllUids();

  /// Verilen UID aralığının başlıklarını çeker.
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopes(List<int> uids);

  /// Belirtilen UID'den küçük en yeni [count] iletinin başlığını çeker.
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeRange({
    required int fromUid,
    required int toUid,
  });

  /// Yalnızca bayrakları çeker (artımlı senkronizasyon).
  Future<Result<List<RemoteFlagState>>> fetchFlags(
    List<int> uids, {
    int? changedSinceModSeq,
  });

  /// İletinin tam gövdesini çeker.
  Future<Result<FetchedBody>> fetchBody(int uid);

  /// Ek dosyanın ikili içeriğini çeker.
  Future<Result<Uint8List>> fetchAttachment(int uid, String partId);

  /// Bayrak ekler veya kaldırır.
  Future<Result<void>> storeFlags({
    required List<int> uids,
    required List<String> flags,
    required bool add,
  });

  /// İletileri başka klasöre taşır.
  ///
  /// [sourcePath] verilirse SELECT ve MOVE aynı kilit altında, tek adımda
  /// yapılır: UID'ler klasöre özgüdür, araya giren başka bir eşitleme farklı
  /// klasörü SELECT ederse `UID MOVE` yanlış klasörde çalışır ve sunucu yine
  /// de "OK" döner (iletiler taşınmaz).
  Future<Result<void>> moveMessages({
    required List<int> uids,
    required String targetPath,
    String? sourcePath,
  });

  /// İletileri kalıcı olarak siler (yalnızca Çöp Kutusu içinde kullanılır).
  Future<Result<void>> deletePermanently(List<int> uids);

  /// Hazır MIME iletisini klasöre ekler. Dönüş: yeni UID (biliniyorsa).
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    List<String> flags = const [],
  });

  /// Klasör oluşturur.
  Future<Result<void>> createMailbox(String path);

  /// Klasörü siler.
  Future<Result<void>> deleteMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
  });

  /// Klasörü yeniden adlandırır/taşır.
  ///
  /// IMAP'te "taşıma" ayrı bir komut değildir: hem ad değişimi (aynı üst
  /// önek + yeni son bileşen) hem üst değişimi (farklı üst önek + aynı son
  /// bileşen) tek bir RENAME komutuyla yapılır. [newPath] hedef TAM yoldur.
  Future<Result<void>> renameMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
    required String newPath,
  });

  /// Bağlantıyı canlı tutar.
  Future<Result<void>> noop();

  /// IDLE başlatır; yeni ileti geldiğinde akış tetiklenir.
  Future<Result<void>> startIdle();
  Future<Result<void>> stopIdle();

  /// IDLE şu an sürüyor mu? IDLE sürerken gönderilen her komut (NOOP dâhil)
  /// onu bitirir; komutu gönderenin bunu bilmesi gerekir.
  bool get isIdling;

  /// Sunucudan gelen "yeni ileti var" bildirimleri.
  Stream<void> get serverChanges;
}

/// Servis katmanının kendi hata tipi.
class ImapServiceException implements Exception {
  const ImapServiceException(this.message);
  final String message;

  @override
  String toString() => 'ImapServiceException: $message';
}

/// `enough_mail` tabanlı uygulama.
class EnoughMailImapService implements ImapService {
  EnoughMailImapService();

  em.ImapClient? _client;
  final Lock _lock = Lock();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  String? _selectedPath;
  bool _idling = false;

  /// Bağlantı kapatılırken her sunucu adımı için beklenen en uzun süre.
  static const Duration _shutdownStep = Duration(seconds: 3);

  /// Oturum açma (LOGIN/AUTH) için beklenen en uzun süre.
  static const Duration _loginTimeout = Duration(seconds: 20);

  /// Tek bir IMAP komutu (LIST/SELECT/FETCH/…) için beklenen en uzun süre.
  ///
  /// Soket açık kalıp sunucu yanıt vermeyi bırakırsa (yük, ağ sorunu) bu
  /// olmadan `await` sonsuza kadar asılı kalır — ekranda "yükleniyor"
  /// göstergesi hiç kapanmaz. `_mapError` zaten `TimeoutException`'ı
  /// tanıyordu; eksik olan bu sınırın konmasıydı.
  static const Duration _commandTimeout = Duration(seconds: 30);

  @override
  Stream<void> get serverChanges => _changes.stream;

  @override
  bool get isConnected => _client?.isLoggedIn ?? false;

  @override
  bool get isIdling => _idling;

  em.ImapClient get _requireClient {
    final client = _client;
    if (client == null) {
      throw StateError('IMAP bağlantısı kurulmadı');
    }
    return client;
  }

  @override
  Future<Result<ServerCapabilities>> connect(
    MailServerConfig config,
  ) => _lock.synchronized(() async {
    try {
      await _teardown();
      final client = em.ImapClient(isLogEnabled: false);
      _client = client;

      await client.connectToServer(
        config.host,
        config.port,
        isSecure: config.isImplicitTls,
        timeout: const Duration(seconds: 25),
      );

      if (config.security == SocketSecurity.startTls) {
        await client.startTls();
      }

      final capabilities = await (switch (config.credential) {
        PasswordCredential(:final password) => client.login(
          config.username,
          password,
        ),
      }).timeout(_loginTimeout);

      _eventSubscription = client.eventBus.on<em.ImapEvent>().listen((event) {
        if (event is em.ImapMessagesExistEvent ||
            event is em.ImapMessagesRecentEvent ||
            event is em.ImapFetchEvent ||
            event is em.ImapExpungeEvent ||
            event is em.ImapVanishedEvent) {
          if (!_changes.isClosed) _changes.add(null);
        } else if (event is em.ImapConnectionLostEvent) {
          _idling = false;
          _selectedPath = null;
          if (!_changes.isClosed) _changes.add(null);
        }
      }, onError: (_) {});

      final names = capabilities.map((c) => c.name).toList();
      return Ok(
        ServerCapabilities(
          raw: names,
          supportsIdle: client.serverInfo.supportsIdle,
          supportsMove: client.serverInfo.supportsMove,
          supportsCondStore: names.any((n) => n.toUpperCase() == 'CONDSTORE'),
          supportsQresync: client.serverInfo.supportsQresync,
          supportsUidPlus: client.serverInfo.supportsUidPlus,
          supportsNotify: names.any((n) => n.toUpperCase() == 'NOTIFY'),
        ),
      );
    } catch (error, stack) {
      await _teardown();
      return Err(_mapError(error, stack));
    }
  });

  @override
  Future<void> disconnect() => _lock.synchronized(_teardown);

  /// Oturumu kapatır.
  ///
  /// Her adım süre sınırlıdır: sunucu yanıt vermezse (ağ koptu, IDLE'da
  /// takıldı) `logout` sonsuza kadar bekler ve kapatmayı bekleyen çıkış
  /// akışı da onunla birlikte kilitlenir.
  Future<void> _teardown() async {
    final wasIdling = _idling;
    _idling = false;
    _selectedPath = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      // IDLE sürerken sunucu yalnızca "DONE" bekler, LOGOUT'a yanıt
      // vermez; önce IDLE bitirilir.
      if (wasIdling) await client.idleDone().timeout(_shutdownStep);
    } catch (_) {}
    try {
      if (client.isLoggedIn) await client.logout().timeout(_shutdownStep);
    } catch (_) {
      // Oturum kapatma başarısız olsa da soketi kapat.
    }
    try {
      await client.disconnect().timeout(_shutdownStep);
    } catch (_) {}
  }

  @override
  Future<Result<List<RemoteMailbox>>> listMailboxes() => _guard(() async {
    final boxes = await _requireClient.listMailboxes(recursive: true);
    return boxes.map(_toRemoteMailbox).toList();
  });

  RemoteMailbox _toRemoteMailbox(em.Mailbox box) {
    SpecialUse? flagUse;
    if (box.flags.contains(em.MailboxFlag.inbox)) {
      flagUse = SpecialUse.inbox;
    } else if (box.flags.contains(em.MailboxFlag.sent)) {
      flagUse = SpecialUse.sent;
    } else if (box.flags.contains(em.MailboxFlag.drafts)) {
      flagUse = SpecialUse.drafts;
    } else if (box.flags.contains(em.MailboxFlag.trash)) {
      flagUse = SpecialUse.trash;
    } else if (box.flags.contains(em.MailboxFlag.junk)) {
      flagUse = SpecialUse.junk;
    } else if (box.flags.contains(em.MailboxFlag.archive)) {
      flagUse = SpecialUse.archive;
    }

    return RemoteMailbox(
      path: box.path,
      encodedPath: box.encodedPath,
      name: box.name,
      delimiter: box.pathSeparator,
      specialUse: flagUse ?? SpecialUse.custom,
      isSelectable: !box.flags.contains(em.MailboxFlag.noSelect),
      isSubscribed: box.flags.contains(em.MailboxFlag.subscribed),
    );
  }

  @override
  Future<Result<MailboxState>> selectMailbox(
    String path, {
    bool enableCondStore = false,
  }) => _guard(() async {
    final box = await _requireClient.selectMailboxByPath(
      path,
      enableCondStore: enableCondStore,
    );
    _selectedPath = path;
    return MailboxState(
      uidValidity: box.uidValidity ?? 0,
      uidNext: box.uidNext ?? 0,
      messageCount: box.messagesExists,
      highestModSeq: box.highestModSequence,
      permanentFlags: box.permanentMessageFlags,
    );
  });

  @override
  Future<Result<List<int>>> searchAllUids() => _guard(() async {
    final result = await _requireClient.uidSearchMessages(
      searchCriteria: 'ALL',
    );
    return result.matchingSequence?.toList() ?? <int>[];
  });

  /// Başlık çekmek için kullanılan FETCH tanımı.
  ///
  /// `BODY.PEEK[HEADER]` kullanılır — `BODY[HEADER]` deseydik sunucu iletiyi
  /// otomatik olarak okundu işaretlerdi ve gelen kutusu ilk açılışta
  /// kendiliğinden okunmuş görünürdü.
  ///
  /// Tam başlık bloğu çekilir çünkü ENVELOPE `References` başlığını
  /// içermez ve konuşma gruplaması bu başlığa bağlıdır.
  static const String _envelopeCriteria =
      '(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE '
      'BODY.PEEK[HEADER])';

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopes(List<int> uids) =>
      _guard(() async {
        if (uids.isEmpty) return <FetchedEnvelope>[];
        final sequence = em.MessageSequence.fromIds(uids, isUid: true);
        final result = await _requireClient.uidFetchMessages(
          sequence,
          _envelopeCriteria,
          responseTimeout: const Duration(seconds: 60),
        );
        return result.messages.map(_toEnvelope).toList();
      });

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeRange({
    required int fromUid,
    required int toUid,
  }) => _guard(() async {
    if (toUid < fromUid) return <FetchedEnvelope>[];
    final sequence = em.MessageSequence.fromRange(
      fromUid,
      toUid,
      isUidSequence: true,
    );
    final result = await _requireClient.uidFetchMessages(
      sequence,
      _envelopeCriteria,
      responseTimeout: const Duration(seconds: 60),
    );
    return result.messages.map(_toEnvelope).toList();
  });

  FetchedEnvelope _toEnvelope(em.MimeMessage message) {
    EmailAddress? toAddress(em.MailAddress? address) => address == null
        ? null
        : EmailAddress(email: address.email, name: address.personalName);

    List<EmailAddress> toList(List<em.MailAddress>? list) =>
        (list ?? const <em.MailAddress>[])
            .map((a) => EmailAddress(email: a.email, name: a.personalName))
            .toList();

    final envelope = message.envelope;
    final date =
        envelope?.date ??
        message.decodeDate() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    var hasAttachments = false;
    try {
      // `hasAttachmentsOrInlineNonTextualParts` gömülü (inline) imzalar/logolar
      // gibi HTML gövdesi içinde `cid:` ile referanslanan, kullanıcının
      // "ek" olarak görmeyeceği parçaları da sayar — bu da listede/arama
      // filtresinde gerçekte eki olmayan iletilerin ek ikonuyla görünmesine
      // yol açar. `findContentInfo()` varsayılan olarak yalnızca gerçek
      // (attachment disposition'lı) parçaları döner; gövde ekran şeridinde
      // gösterilen ("Ekleri Var" filtresiyle tutarlı) küme de tam olarak bu.
      hasAttachments = message.findContentInfo().isNotEmpty;
    } catch (_) {
      // Bozuk BODYSTRUCTURE bütün senkronizasyonu durdurmamalı.
      hasAttachments = false;
    }

    return FetchedEnvelope(
      uid: message.uid ?? 0,
      date: date.toUtc(),
      subject: _safeSubject(message, envelope),
      from: toAddress(envelope?.from?.firstOrNull ?? message.from?.firstOrNull),
      to: toList(envelope?.to ?? message.to),
      cc: toList(envelope?.cc ?? message.cc),
      bcc: toList(envelope?.bcc ?? message.bcc),
      flags: message.flags ?? const <String>[],
      sizeBytes: message.size ?? 0,
      hasAttachments: hasAttachments,
      messageId: envelope?.messageId ?? message.getHeaderValue('message-id'),
      inReplyTo: envelope?.inReplyTo ?? message.getHeaderValue('in-reply-to'),
      references: message.getHeaderValue('references'),
    );
  }

  /// Standart dışı kodlanmış konu başlıkları uygulamayı çökertmemeli.
  String _safeSubject(em.MimeMessage message, em.Envelope? envelope) {
    try {
      final decoded = message.decodeSubject() ?? envelope?.subject;
      if (decoded != null && decoded.isNotEmpty) return decoded;
    } catch (_) {
      // Çözülemeyen başlık ham hâliyle gösterilir.
    }
    return envelope?.subject ?? message.getHeaderValue('subject') ?? '';
  }

  @override
  Future<Result<List<RemoteFlagState>>> fetchFlags(
    List<int> uids, {
    int? changedSinceModSeq,
  }) => _guard(() async {
    if (uids.isEmpty) return <RemoteFlagState>[];
    final sequence = em.MessageSequence.fromIds(uids, isUid: true);
    final result = await _requireClient.uidFetchMessages(
      sequence,
      '(UID FLAGS)',
      changedSinceModSequence: changedSinceModSeq,
      responseTimeout: const Duration(seconds: 45),
    );
    return result.messages
        .where((m) => m.uid != null)
        .map(
          (m) =>
              RemoteFlagState(uid: m.uid!, flags: m.flags ?? const <String>[]),
        )
        .toList();
  });

  @override
  Future<Result<FetchedBody>> fetchBody(int uid) => _guard(() async {
    final sequence = em.MessageSequence.fromId(uid, isUid: true);
    final result = await _requireClient.uidFetchMessages(
      sequence,
      '(UID FLAGS BODY.PEEK[])',
      responseTimeout: const Duration(seconds: 90),
    );
    final message = result.messages.firstOrNull;
    if (message == null) {
      return const FetchedBody();
    }

    String? plain;
    String? html;
    try {
      plain = message.decodeTextPlainPart();
    } catch (_) {}
    try {
      html = message.decodeTextHtmlPart();
    } catch (_) {}
    if (plain == null && html == null) {
      try {
        plain = message.decodeContentText();
      } catch (_) {}
    }

    final attachments = <FetchedAttachment>[];
    try {
      for (final info in message.findContentInfo()) {
        attachments.add(
          FetchedAttachment(
            partId: info.fetchId,
            fileName: info.fileName ?? 'dosya',
            mimeType:
                info.contentType?.mediaType.text ?? 'application/octet-stream',
            sizeBytes: info.size ?? 0,
            contentId: info.cid,
          ),
        );
      }
      for (final info in message.findContentInfo(
        disposition: em.ContentDisposition.inline,
      )) {
        if (info.isText) continue;
        attachments.add(
          FetchedAttachment(
            partId: info.fetchId,
            fileName: info.fileName ?? 'gomulu',
            mimeType:
                info.contentType?.mediaType.text ?? 'application/octet-stream',
            sizeBytes: info.size ?? 0,
            contentId: info.cid,
            isInline: true,
          ),
        );
      }
    } catch (_) {
      // Ek listesi çıkarılamadıysa gövde yine de gösterilir.
    }

    return FetchedBody(plainText: plain, html: html, attachments: attachments);
  });

  @override
  Future<Result<Uint8List>> fetchAttachment(int uid, String partId) =>
      _guard(() async {
        final sequence = em.MessageSequence.fromId(uid, isUid: true);
        final result = await _requireClient.uidFetchMessages(
          sequence,
          '(BODY.PEEK[$partId])',
          responseTimeout: const Duration(minutes: 3),
        );
        final message = result.messages.firstOrNull;
        if (message == null) {
          throw const ImapServiceException('Ek bulunamadı');
        }
        final part = message.getPart(partId);
        final data =
            part?.decodeContentBinary() ??
            message.decodeContentBinary() ??
            Uint8List(0);
        return data;
      });

  @override
  Future<Result<void>> storeFlags({
    required List<int> uids,
    required List<String> flags,
    required bool add,
  }) => _guard(() async {
    if (uids.isEmpty || flags.isEmpty) return;
    // Tek komutta gönderilir: 200 ileti için 200 istek atılmaz.
    final sequence = em.MessageSequence.fromIds(uids, isUid: true);
    await _requireClient.uidStore(
      sequence,
      flags,
      action: add ? em.StoreAction.add : em.StoreAction.remove,
      silent: true,
    );
  });

  @override
  Future<Result<void>> moveMessages({
    required List<int> uids,
    required String targetPath,
    String? sourcePath,
  }) => _guard(() async {
    if (uids.isEmpty) return;
    final sequence = em.MessageSequence.fromIds(uids, isUid: true);
    final client = _requireClient;
    if (sourcePath != null && _selectedPath != sourcePath) {
      await client.selectMailboxByPath(sourcePath);
      _selectedPath = sourcePath;
    }
    if (client.serverInfo.supportsMove) {
      await client.uidMove(sequence, targetMailboxPath: targetPath);
      return;
    }
    // MOVE desteklenmiyorsa: KOPYALA + \Deleted + EXPUNGE
    await client.uidCopy(sequence, targetMailboxPath: targetPath);
    await client.uidStore(
      sequence,
      [em.MessageFlags.deleted],
      action: em.StoreAction.add,
      silent: true,
    );
    if (client.serverInfo.supportsUidPlus) {
      await client.uidExpunge(sequence);
    } else {
      await client.expunge();
    }
  });

  @override
  Future<Result<void>> deletePermanently(List<int> uids) => _guard(() async {
    if (uids.isEmpty) return;
    final sequence = em.MessageSequence.fromIds(uids, isUid: true);
    final client = _requireClient;
    await client.uidStore(
      sequence,
      [em.MessageFlags.deleted],
      action: em.StoreAction.add,
      silent: true,
    );
    // UIDPLUS varsa yalnızca seçilenler silinir; yoksa klasördeki tüm
    // \Deleted işaretliler silinir — bu yüzden EXPUNGE öncesi başka
    // iletiye \Deleted konmaz.
    if (client.serverInfo.supportsUidPlus) {
      await client.uidExpunge(sequence);
    } else {
      await client.expunge();
    }
  });

  @override
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    List<String> flags = const [],
  }) => _guard(() async {
    final result = await _requireClient.appendMessageText(
      mimeSource,
      targetMailboxPath: targetPath,
      flags: flags.isEmpty ? null : flags,
      responseTimeout: const Duration(minutes: 2),
    );
    return result.responseCodeAppendUid?.targetSequence.toList().firstOrNull;
  });

  @override
  Future<Result<void>> createMailbox(String path) => _guard(() async {
    await _requireClient.createMailbox(path);
  });

  @override
  Future<Result<void>> deleteMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
  }) => _guard(() async {
    await _requireClient.deleteMailbox(
      _syntheticMailbox(
        path: path,
        encodedPath: encodedPath,
        delimiter: delimiter,
      ),
    );
  });

  @override
  Future<Result<void>> renameMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
    required String newPath,
  }) => _guard(() async {
    await _requireClient.renameMailbox(
      _syntheticMailbox(
        path: path,
        encodedPath: encodedPath,
        delimiter: delimiter,
      ),
      newPath,
    );
  });

  /// [em.ImapClient]'ın `RENAME`/`DELETE` gibi komutları yalnızca bir
  /// [em.Mailbox] nesnesi kabul eder, ham bir yol (path) değil — ama tek
  /// ihtiyacımız olan bilgi yoldur (yerelde de sadece onu tutuyoruz, bkz.
  /// `MailboxRow`). Paketin kendisi de tam bu deseni kullanır (bkz.
  /// `ImapClient.selectMailboxByPath`): eldeki yol bilgisinden minimal,
  /// sahte bir [em.Mailbox] üretilir — sunucuya yalnızca `encodedPath`
  /// gider, diğer alanlar (bayraklar, mesaj sayıları) bu komutlarda
  /// okunmaz.
  em.Mailbox _syntheticMailbox({
    required String path,
    required String encodedPath,
    required String delimiter,
  }) {
    final effectivePath = encodedPath.isEmpty ? path : encodedPath;
    final splitIndex = effectivePath.lastIndexOf(delimiter);
    final name = splitIndex == -1
        ? effectivePath
        : effectivePath.substring(splitIndex + delimiter.length);
    return em.Mailbox(
      encodedName: name,
      encodedPath: effectivePath,
      pathSeparator: delimiter,
      flags: const [],
    );
  }

  @override
  Future<Result<void>> noop() => _guard(() async {
    await _requireClient.noop();
  });

  @override
  Future<Result<void>> startIdle() => _guard(() async {
    if (_idling) return;
    if (!_requireClient.serverInfo.supportsIdle) return;
    if (_selectedPath == null) return;
    await _requireClient.idleStart();
    _idling = true;
  });

  @override
  Future<Result<void>> stopIdle() => _guard(() async {
    if (!_idling) return;
    _idling = false;
    await _requireClient.idleDone();
  });

  /// Tüm komutları tek kuyruktan geçirir ve hataları [AppFailure]'a çevirir.
  Future<Result<T>> _guard<T>(Future<T> Function() action) =>
      _lock.synchronized(() async {
        try {
          if (!isConnected) {
            return const Err(ConnectionFailure(detail: 'oturum açık değil'));
          }
          // IDLE sırasında başka komut gönderilemez.
          if (_idling) {
            _idling = false;
            try {
              await _requireClient.idleDone();
            } catch (_) {}
          }
          return Ok(await action().timeout(_commandTimeout));
        } catch (error, stack) {
          return Err(_mapError(error, stack));
        }
      });

  AppFailure _mapError(Object error, StackTrace stack) {
    if (error is SocketException) {
      return ConnectionFailure(detail: error.message);
    }
    if (error is HandshakeException) {
      return TlsFailure(detail: error.message);
    }
    if (error is TlsException) {
      return TlsFailure(detail: error.message);
    }
    if (error is TimeoutException) {
      return const ConnectionFailure(detail: 'zaman aşımı');
    }
    if (error is em.ImapException) {
      return _mapImapMessage(error.message ?? error.toString());
    }
    if (error is em.MailException) {
      return _mapImapMessage(error.message ?? error.toString());
    }
    if (error is ImapServiceException) {
      return ServerFailure(detail: error.message);
    }
    if (error is StateError) {
      return ConnectionFailure(detail: error.message);
    }
    return UnknownFailure(detail: '$error');
  }

  AppFailure _mapImapMessage(String message) {
    final upper = message.toUpperCase();
    if (upper.contains('AUTHENTICATIONFAILED') ||
        upper.contains('AUTHENTICATION FAILED') ||
        upper.contains('INVALID CREDENTIALS') ||
        upper.contains('LOGIN FAILED') ||
        upper.contains('[AUTHORIZATIONFAILED]')) {
      return AuthFailure(detail: message);
    }
    if (upper.contains('OVERQUOTA') || upper.contains('QUOTA')) {
      return QuotaExceededFailure(detail: message);
    }
    if (upper.contains('TRYCREATE') || upper.contains('NONEXISTENT')) {
      return MailboxNotFoundFailure(detail: message);
    }
    return ServerFailure(detail: message);
  }

  /// Kaynakları serbest bırakır.
  Future<void> dispose() async {
    await disconnect();
    await _changes.close();
  }
}
