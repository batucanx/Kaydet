import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'attachment_files.dart';
import 'inline_image_collector.dart';
import 'mail_text_decoder.dart';
import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/foundation.dart' show kDebugMode;
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

  /// Kimlik bilgisini ve sunucu ayarını, uygulamanın canlı oturumuna
  /// DOKUNMADAN sınar: ayrı, geçici bir bağlantı açıp oturum açar ve kapatır.
  ///
  /// [connect] kullanılamaz: o, ortak oturumu kapatıp yerine geçer; giriş
  /// ekranından yeni bir hesap denenirken etkin hesabın bağlantısı kopar ve
  /// süren işlemleri başka bir sunucuya karışır.
  Future<Result<void>> verify(MailServerConfig config);

  bool get isConnected;

  /// Tüm klasörleri listeler.
  Future<Result<List<RemoteMailbox>>> listMailboxes();

  /// Klasörü seçer ve durumunu döner.
  Future<Result<MailboxState>> selectMailbox(
    String path, {
    String? encodedPath,
    bool enableCondStore = false,
  });

  /// Seçili klasörü DEĞİŞTİRMEDEN klasörün durumunu (`STATUS`) sorar: UIDVALIDITY,
  /// UIDNEXT ve ileti sayısı. Ucuz bir "değişti mi?" yoklaması içindir.
  /// [includeUnseen] `true` ise okunmamış sayısı da ([MailboxState.unseenCount])
  /// istenir.
  Future<Result<MailboxState>> statusMailbox(
    String path, {
    String? encodedPath,
    bool includeUnseen = false,
  });

  /// [path] klasöründeki okunmamış VE `\Deleted` işaretli olmayan ileti sayısı
  /// (`UID SEARCH UNSEEN UNDELETED`).
  ///
  /// `STATUS (UNSEEN)` `\Deleted` işaretli (henüz EXPUNGE edilmemiş) iletileri
  /// de sayar; diğer istemciler ve bu uygulamanın listesi onları gizler, yani
  /// rozet listede görünmeyen iletiler için "okunmamış" der. Bu komut listede
  /// görünen kümeyle birebir aynı sayıyı verir.
  ///
  /// Klasör geçici olarak seçilir; önceden seçili klasör (IDLE'ın izlediği)
  /// geri seçilir.
  Future<Result<int>> countUnseen({required String path, String? encodedPath});

  /// Klasördeki tüm UID'leri döner (silinenleri tespit etmek için).
  Future<Result<List<int>>> searchAllUids();

  /// Verilen UID aralığının başlıklarını çeker.
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopes(List<int> uids);

  /// Belirtilen sıra numarası (sequence number) aralığındaki iletilerin başlıklarını çeker.
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeSequenceRange({
    required int fromSeq,
    required int toSeq,
  });

  /// Verilen UID listesinden sunucuda hâlâ var olanları döner (silinenleri tespit etmek için).
  Future<Result<List<int>>> searchUidsInSet(List<int> uids);

  /// Bir UID'nin IMAP sıra numarasını (sequence number) döner. Bulunamazsa `null` döner.
  Future<Result<int?>> searchSequenceByUid(int uid);

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

  /// İletinin tam gövdesini çeker. İleti seçili klasörde yoksa (silinmiş ya da
  /// UID başka klasöre ait) [MessageNotFoundFailure] döner — boş gövde
  /// "başarı" sayılıp önbelleğe yazılmaz.
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
  ///
  /// [sourceEncodedPath] / [targetEncodedPath] sunucuya gerçekte gönderilen
  /// (modified UTF-7) yollardır. Verilmezse yol türetilir; ASCII olmayan klasör
  /// adlarında (ör. "Çöp Kutusu") ham yol göndermek `NONEXISTENT` ile
  /// başarısız olur.
  Future<Result<void>> moveMessages({
    required List<int> uids,
    required String targetPath,
    String? sourcePath,
    String? sourceEncodedPath,
    String? targetEncodedPath,
  });

  /// İletileri kalıcı olarak siler (yalnızca Çöp Kutusu içinde kullanılır).
  Future<Result<void>> deletePermanently(List<int> uids);

  /// Hazır MIME iletisini klasöre ekler. Dönüş: yeni UID (biliniyorsa).
  Future<Result<int?>> appendMessage({
    required String mimeSource,
    required String targetPath,
    String? encodedPath,
    List<String> flags = const [],
  });

  /// Seçili klasördeki iletinin HAM kaynağını (başlıklar + tüm parçalar) döner.
  /// İade iletilerini ayrıştırmak için kullanılır; en çok [maxChars] karakter.
  Future<Result<String>> fetchRawSource(int uid, {int maxChars = 200000});

  /// [path] klasöründe `Message-ID` başlığı [messageId] olan ileti var mı?
  ///
  /// Gönderilen iletinin Gönderilenler klasöründe gerçekten durduğunu sunucudan
  /// doğrulamak için kullanılır. `<>` parantezli ve parantezsiz biçimler eşdeğerdir.
  /// SELECT ve SEARCH aynı kilit altında yapılır (bkz. [moveMessages]).
  Future<Result<bool>> existsByMessageId({
    required String path,
    String? encodedPath,
    required String messageId,
  });

  /// Klasör oluşturur.
  Future<Result<void>> createMailbox(String path);

  /// Klasörü abonelik listesinden çıkarır (`UNSUBSCRIBE`). Birçok sunucu yeni klasörü
  /// kendiliğinden abone yapar ve webmail onu listeler; klasör ve iletileri etkilenmez.
  Future<Result<void>> unsubscribeMailbox(String encodedPath);

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
  ///
  /// [timeout] verilirse varsayılan komut süresi yerine o kullanılır; dolarsa
  /// bağlantı kapatılır (bkz. `_guard`). Arka plandan dönüşte soketin hâlâ
  /// canlı olup olmadığını hızlıca anlamak içindir.
  Future<Result<void>> noop({Duration? timeout});

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

/// İstenen UID seçili klasörde bulunamadı.
class MessageNotFoundException implements Exception {
  const MessageNotFoundException();

  @override
  String toString() => 'MessageNotFoundException';
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

  /// Tek bir IMAP komutu (LIST/SELECT/STORE/…) için varsayılan en uzun süre.
  ///
  /// Soket açık kalıp sunucu yanıt vermeyi bırakırsa (yük, ağ sorunu) bu
  /// olmadan `await` sonsuza kadar asılı kalır — ekranda "yükleniyor"
  /// göstergesi hiç kapanmaz.
  static const Duration _commandTimeout = Duration(seconds: 30);

  /// Uzun süren komutların (zarf/bayrak/gövde/ek çekme, APPEND) `enough_mail`
  /// düzeyindeki yanıt zaman aşımları. `_guard`'ın dış sınırı bunlardan
  /// [_outerSlack] kadar UZUN olmak zorundadır: kısa olursa (eskiden herkese
  /// 30 sn uygulanıyordu) büyük ek indirmeleri ve APPEND'ler yanıt gelmeden
  /// kesilirdi.
  static const Duration _envelopeResponseTimeout = Duration(seconds: 60);
  static const Duration _flagsResponseTimeout = Duration(seconds: 45);
  static const Duration _bodyResponseTimeout = Duration(seconds: 90);
  static const Duration _attachmentResponseTimeout = Duration(minutes: 3);
  static const Duration _appendResponseTimeout = Duration(minutes: 2);
  static const Duration _outerSlack = Duration(seconds: 15);

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

  @override
  Future<Result<void>> verify(MailServerConfig config) async {
    // Ortak oturuma (`_client`, `_lock`, `_selectedPath`) HİÇ dokunulmaz.
    em.ImapClient? client;
    try {
      final probe = client = em.ImapClient(isLogEnabled: false);
      await probe.connectToServer(
        config.host,
        config.port,
        isSecure: config.isImplicitTls,
        timeout: const Duration(seconds: 25),
      );
      if (config.security == SocketSecurity.startTls) {
        await probe.startTls();
      }
      await (switch (config.credential) {
        PasswordCredential(:final password) => probe.login(
          config.username,
          password,
        ),
      }).timeout(_loginTimeout);
      return okVoid;
    } catch (error, stack) {
      return Err(_mapError(error, stack));
    } finally {
      if (client != null) await _closeProbe(client);
    }
  }

  /// [verify]'ın geçici bağlantısını kapatır; her adım süre sınırlıdır.
  Future<void> _closeProbe(em.ImapClient client) async {
    try {
      if (client.isLoggedIn) await client.logout().timeout(_shutdownStep);
    } catch (_) {}
    try {
      await client.disconnect().timeout(_shutdownStep);
    } catch (_) {}
  }

  /// Oturumu kapatır.
  ///
  /// Her adım süre sınırlıdır: sunucu yanıt vermezse (ağ koptu, IDLE'da
  /// takıldı) `logout` sonsuza kadar bekler ve kapatmayı bekleyen çıkış
  /// akışı da onunla birlikte kilitlenir.
  ///
  /// [graceful] `false` ise (yanıtsız kalmış bir komut yüzünden bağlantı
  /// güvenilmez) IDLE/LOGOUT nezaketi atlanır: sunucu zaten yanıt vermiyor,
  /// bunları beklemek yalnızca gecikme katardı — soket doğrudan kapatılır.
  Future<void> _teardown({bool graceful = true}) async {
    final wasIdling = _idling;
    _idling = false;
    _selectedPath = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    final client = _client;
    _client = null;
    if (client == null) return;
    if (graceful) {
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
    }
    try {
      await client.disconnect().timeout(_shutdownStep);
    } catch (_) {}
  }

  @override
  Future<Result<List<RemoteMailbox>>> listMailboxes() => _guard(() async {
    final boxes = await _requireClient.listMailboxes(recursive: true);
    return boxes.map(_toRemoteMailbox).toList();
  }, timeout: const Duration(seconds: 60));

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
    String? encodedPath,
    bool enableCondStore = false,
  }) => _guard(() async {
    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    final effectivePath = (encodedPath != null && encodedPath.isNotEmpty)
        ? encodedPath
        : em.Mailbox.encode(path, separator);

    em.Mailbox box;
    try {
      box = await client.selectMailboxByPath(
        effectivePath,
        enableCondStore: enableCondStore,
      );
    } on em.ImapException catch (error) {
      // Bazı IMAP sunucuları UTF-7 yerine doğrudan UTF-8 yolunu bekleyebilir (RFC 6855 UTF8=ACCEPT).
      // Eğer denenen yol path'ten farklıysa unencoded path ile de bir kez dene.
      if (effectivePath != path &&
          (error.message?.toUpperCase().contains('NONEXISTENT') ?? false)) {
        box = await client.selectMailboxByPath(
          path,
          enableCondStore: enableCondStore,
        );
      } else {
        rethrow;
      }
    }
    _selectedPath = effectivePath;
    final state = MailboxState(
      uidValidity: box.uidValidity ?? 0,
      uidNext: box.uidNext ?? 0,
      messageCount: box.messagesExists,
      highestModSeq: box.highestModSequence,
      permanentFlags: box.permanentMessageFlags,
    );
    if (kDebugMode) {
      print(
        '[IMAP SELECT] path="$path", encoded="$effectivePath", '
        'EXISTS=${state.messageCount}, UIDVALIDITY=${state.uidValidity}, '
        'UIDNEXT=${state.uidNext}, HIGHESTMODSEQ=${state.highestModSeq}',
      );
    }
    return state;
  });

  @override
  Future<Result<MailboxState>> statusMailbox(
    String path, {
    String? encodedPath,
    bool includeUnseen = false,
  }) => _guard(() async {
    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    final effectivePath = (encodedPath != null && encodedPath.isNotEmpty)
        ? encodedPath
        : em.Mailbox.encode(path, separator);
    final box = await client.statusMailbox(
      em.Mailbox(
        encodedName: effectivePath,
        encodedPath: effectivePath,
        flags: const [],
        pathSeparator: separator,
      ),
      [
        em.StatusFlags.uidValidity,
        em.StatusFlags.uidNext,
        em.StatusFlags.messages,
        if (includeUnseen) em.StatusFlags.unseen,
      ],
    );
    final state = MailboxState(
      uidValidity: box.uidValidity ?? 0,
      uidNext: box.uidNext ?? 0,
      messageCount: box.messagesExists,
      unseenCount: includeUnseen ? box.messagesUnseen : null,
    );
    if (kDebugMode) {
      print(
        '[IMAP STATUS] path="$path", encoded="$effectivePath", '
        'EXISTS=${state.messageCount}, UIDVALIDITY=${state.uidValidity}, '
        'UIDNEXT=${state.uidNext}',
      );
    }
    return state;
  });

  @override
  Future<Result<int>> countUnseen({
    required String path,
    String? encodedPath,
  }) => _guard(() async {
    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    final wirePath = (encodedPath != null && encodedPath.isNotEmpty)
        ? encodedPath
        : em.Mailbox.encode(path, separator);
    final previous = _selectedPath;
    final switched = previous != wirePath;
    if (switched) {
      // Başarısız SELECT sonrası seçili klasör belirsizdir; sonraki komutlar
      // `_selectedPath`e güvenmesin.
      _selectedPath = null;
      await client.selectMailboxByPath(wirePath);
      _selectedPath = wirePath;
    }
    try {
      final result = await client.uidSearchMessages(
        searchCriteria: 'UNSEEN UNDELETED',
      );
      return result.matchingSequence?.toList().length ?? 0;
    } finally {
      // IDLE'ın ve sonraki işlemlerin beklediği klasör geri seçilir.
      if (switched && previous != null) {
        try {
          await client.selectMailboxByPath(previous);
          _selectedPath = previous;
        } on Object catch (_) {
          _selectedPath = null;
        }
      }
    }
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
  /// Tam başlık bloğu DEĞİL, yalnızca gereken alanlar çekilir: ENVELOPE
  /// `References` başlığını içermez ve konuşma gruplaması bu başlığa bağlıdır
  /// (`_toEnvelope` yalnızca bunları ve ENVELOPE'un eksik kalırsa yedek olarak
  /// kullandığı alanları okur). Tam blok (Received zinciri, DKIM/ARC imzaları)
  /// ileti başına birkaç KB'tır; 50-100 iletilik bir ilk indirmede yüzlerce KB
  /// gereksiz veri ve yavaş bağlantıda saniyeler demektir.
  static const String _envelopeCriteria =
      '(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE '
      'BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO MESSAGE-ID SUBJECT '
      'DATE FROM TO CC)])';

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopes(List<int> uids) =>
      _guard(() async {
        if (uids.isEmpty) return <FetchedEnvelope>[];
        final sequence = em.MessageSequence.fromIds(uids, isUid: true);
        final result = await _requireClient.uidFetchMessages(
          sequence,
          _envelopeCriteria,
          responseTimeout: _envelopeResponseTimeout,
        );
        return result.messages.map(_toEnvelope).toList();
      }, timeout: _envelopeResponseTimeout + _outerSlack);

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
      responseTimeout: _envelopeResponseTimeout,
    );
    return result.messages.map(_toEnvelope).toList();
  }, timeout: _envelopeResponseTimeout + _outerSlack);

  @override
  Future<Result<List<FetchedEnvelope>>> fetchEnvelopeSequenceRange({
    required int fromSeq,
    required int toSeq,
  }) => _guard(() async {
    if (toSeq < fromSeq || fromSeq < 1) return <FetchedEnvelope>[];
    final sequence = em.MessageSequence.fromRange(
      fromSeq,
      toSeq,
      isUidSequence: false,
    );
    final result = await _requireClient.fetchMessages(
      sequence,
      _envelopeCriteria,
      responseTimeout: _envelopeResponseTimeout,
    );
    return result.messages.map(_toEnvelope).toList();
  }, timeout: _envelopeResponseTimeout + _outerSlack);

  @override
  Future<Result<List<int>>> searchUidsInSet(List<int> uids) =>
      _guard(() async {
        if (uids.isEmpty) return <int>[];
        final found = <int>[];
        const chunkSize = 150;
        for (var i = 0; i < uids.length; i += chunkSize) {
          final chunk = uids.sublist(i, min(i + chunkSize, uids.length));
          final result = await _requireClient.uidSearchMessages(
            searchCriteria: 'UID ${chunk.join(',')}',
          );
          final matches = result.matchingSequence?.toList();
          if (matches != null) {
            found.addAll(matches);
          }
        }
        return found;
      });

  @override
  Future<Result<int?>> searchSequenceByUid(int uid) => _guard(() async {
    final result = await _requireClient.searchMessages(
      searchCriteria: 'UID $uid',
    );
    return result.matchingSequence?.toList().firstOrNull;
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
      responseTimeout: _flagsResponseTimeout,
    );
    return result.messages
        .where((m) => m.uid != null)
        .map(
          (m) =>
              RemoteFlagState(uid: m.uid!, flags: m.flags ?? const <String>[]),
        )
        .toList();
  }, timeout: _flagsResponseTimeout + _outerSlack);

  @override
  Future<Result<FetchedBody>> fetchBody(int uid) => _guard(() async {
    final sequence = em.MessageSequence.fromId(uid, isUid: true);
    final result = await _requireClient.uidFetchMessages(
      sequence,
      '(UID FLAGS BODY.PEEK[])',
      responseTimeout: _bodyResponseTimeout,
    );
    final message = result.messages.firstOrNull;
    if (message == null) {
      // Boş bir gövdeyi "başarı" diye döndürmek, çağıranın onu önbelleğe
      // yazıp iletiyi kalıcı olarak boş göstermesine yol açardı.
      throw const MessageNotFoundException();
    }

    String? plain;
    String? html;
    try {
      plain = MailTextDecoder.plain(message);
    } catch (_) {}
    try {
      html = MailTextDecoder.html(message);
    } catch (_) {}
    if (html != null) {
      try {
        // WebView `cid:` şemasını bilmez: gömülü görseller `data:` olur.
        html = InlineImageCollector.resolve(message, html);
      } catch (_) {
        // Çözülemedi: gövde `cid:` başvurularıyla gösterilir (görsel kırık).
      }
    }
    if (plain == null && html == null) {
      try {
        plain = message.decodeContentText();
      } catch (_) {}
    }

    String resolveAttachmentName(
      String? name,
      String? mime, {
      required String fallback,
    }) {
      final base = (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : fallback;
      if (base.contains('.')) return base;
      final m = (mime ?? '').toLowerCase();
      final ext = switch (m) {
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
          '.docx',
        'application/msword' => '.doc',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
          '.xlsx',
        'application/vnd.ms-excel' => '.xls',
        'application/pdf' => '.pdf',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
          '.pptx',
        'application/vnd.ms-powerpoint' => '.ppt',
        'text/plain' => '.txt',
        'text/csv' => '.csv',
        'message/rfc822' ||
        'application/eml' ||
        'application/x-eml' ||
        'message/global' =>
          '.eml',
        'application/zip' => '.zip',
        _ => '',
      };
      return '$base$ext';
    }

    final attachments = <FetchedAttachment>[];
    try {
      final infos = message.findContentInfo();
      // `enough_mail`, iletilen bir iletinin (message/rfc822) İÇİNDEKİ ekleri
      // dış parçayla AYNI parça numarasıyla listeler; indirilince hepsi dış
      // .eml'i getirirdi. Yalnızca dış rfc822 parçası gerçek ektir.
      final rfc822Ids = {
        for (final i in infos)
          if (i.contentType?.mediaType.sub == em.MediaSubtype.messageRfc822)
            i.fetchId,
      };

      int resolveAttachmentSize(em.ContentInfo info) {
        if (info.size != null && info.size! > 0) {
          return info.size!;
        }
        final part = message.getPart(info.fetchId);
        if (part != null) {
          if (part.mimeData is em.BinaryMimeData) {
            final data = (part.mimeData as em.BinaryMimeData).data;
            if (data.isNotEmpty) return data.length;
          } else if (part.mimeData is em.TextMimeData) {
            final text = (part.mimeData as em.TextMimeData).text;
            if (text.isNotEmpty) return utf8.encode(text).length;
          }
          final binary = part.decodeContentBinary();
          if (binary != null && binary.isNotEmpty) return binary.length;
          final text = part.decodeContentText();
          if (text != null && text.isNotEmpty) return utf8.encode(text).length;
        }
        return 0;
      }

      for (final info in infos) {
        if (rfc822Ids.contains(info.fetchId) &&
            info.contentType?.mediaType.sub != em.MediaSubtype.messageRfc822) {
          continue;
        }
        final mime =
            info.contentType?.mediaType.text ?? 'application/octet-stream';
        attachments.add(
          FetchedAttachment(
            partId: info.fetchId,
            fileName: resolveAttachmentName(
              info.fileName,
              mime,
              fallback: 'dosya',
            ),
            mimeType: mime,
            sizeBytes: resolveAttachmentSize(info),
            contentId: info.cid,
          ),
        );
      }
      for (final info in message.findContentInfo(
        disposition: em.ContentDisposition.inline,
      )) {
        if (info.isText || rfc822Ids.contains(info.fetchId)) continue;
        final mime =
            info.contentType?.mediaType.text ?? 'application/octet-stream';
        attachments.add(
          FetchedAttachment(
            partId: info.fetchId,
            fileName: resolveAttachmentName(
              info.fileName,
              mime,
              fallback: 'gomulu',
            ),
            mimeType: mime,
            sizeBytes: resolveAttachmentSize(info),
            contentId: info.cid,
            isInline: true,
          ),
        );
      }
    } catch (_) {
      // Ek listesi çıkarılamadıysa gövde yine de gösterilir.
    }

    return FetchedBody(plainText: plain, html: html, attachments: attachments);
  }, timeout: _bodyResponseTimeout + _outerSlack);

  @override
  Future<Result<Uint8List>> fetchAttachment(int uid, String partId) =>
      _guard(() async {
        final sequence = em.MessageSequence.fromId(uid, isUid: true);
        final fetchQuery = partId.isNotEmpty
            ? '(BODY.PEEK[$partId.MIME] BODY.PEEK[$partId])'
            : '(BODY.PEEK[])';

        em.FetchImapResult result;
        try {
          result = await _requireClient.uidFetchMessages(
            sequence,
            fetchQuery,
            responseTimeout: _attachmentResponseTimeout,
          );
        } catch (_) {
          // Bazı IMAP sunucuları birleşik BODY.PEEK[$partId.MIME] BODY.PEEK[$partId]
          // sorgusunu desteklemez; doğrudan tekil parça sorgusuna geri düşülür.
          result = await _requireClient.uidFetchMessages(
            sequence,
            partId.isNotEmpty ? '(BODY.PEEK[$partId])' : '(BODY.PEEK[])',
            responseTimeout: _attachmentResponseTimeout,
          );
        }

        final message = result.messages.firstOrNull;
        if (message == null) {
          throw const MessageNotFoundException();
        }

        // İlgili parçayı bul
        final part = message.getPart(partId);
        final mimePart = partId.isNotEmpty ? message.getPart('$partId.MIME') : null;

        // Header'lar $partId.MIME içinde bulunabilir ($partId içinde containsHeader: false olabilir)
        final fileName = (part?.decodeFileName() ?? mimePart?.decodeFileName() ?? '')
            .trim()
            .toLowerCase();
        final contentType = (part?.getHeaderValue('content-type') ??
                mimePart?.getHeaderValue('content-type') ??
                part?.mediaType.text ??
                '')
            .trim()
            .toLowerCase();
        final encoding = (part?.getHeaderValue('content-transfer-encoding') ??
                mimePart?.getHeaderValue('content-transfer-encoding') ??
                '')
            .trim()
            .toLowerCase();

        final isEmlOrRfc822 = part?.mediaType.sub == em.MediaSubtype.messageRfc822 ||
            mimePart?.mediaType.sub == em.MediaSubtype.messageRfc822 ||
            contentType.contains('rfc822') ||
            contentType.contains('eml') ||
            fileName.endsWith('.eml') ||
            fileName.endsWith('.rfc822') ||
            fileName.endsWith('.nws');
        final isBase64 = encoding == 'base64' || encoding == 'b';

        Uint8List? data;

        if (part != null) {
          if (isEmlOrRfc822 && !isBase64) {
            // EML / RFC 822 ekleri: decodeContentBinary() 8bit/none kodlamada
            // satır sonlarını sildiği için (replaceAll('\r\n', '')) asla çağrılmamalıdır!
            // Ham MIME veya Text verisi satır sonları korunarak doğrudan bayt olarak alınır.
            if (part.mimeData is em.BinaryMimeData) {
              final raw = (part.mimeData as em.BinaryMimeData).data;
              if (raw.isNotEmpty) data = raw;
            } else if (part.mimeData is em.TextMimeData) {
              final raw = (part.mimeData as em.TextMimeData).text;
              if (raw.isNotEmpty) data = Uint8List.fromList(utf8.encode(raw));
            } else {
              final text = part.decodeContentText();
              if (text != null && text.isNotEmpty) {
                data = Uint8List.fromList(utf8.encode(text));
              }
            }
          } else if (part.mimeData is em.TextMimeData && !isBase64) {
            final raw = (part.mimeData as em.TextMimeData).text;
            if (raw.isNotEmpty) data = Uint8List.fromList(utf8.encode(raw));
          } else if (part.mimeData is em.BinaryMimeData && !isBase64) {
            final raw = (part.mimeData as em.BinaryMimeData).data;
            if (raw.isNotEmpty) data = raw;
          }

          data ??= part.decodeContentBinary();
        } else if (message.parts == null || message.parts!.isEmpty) {
          // Çok parçalı olmayan ileti: ek, iletinin kendisidir.
          data = message.decodeContentBinary();
        } else {
          // Parça doğrudan bulunamadıysa parts içindeki tekil parçayı veya message'ı dene
          final candidate = (message.parts?.length == 1 ? message.parts!.first : null);
          if (candidate != null) {
            if (isEmlOrRfc822 && !isBase64) {
              if (candidate.mimeData is em.BinaryMimeData) {
                data = (candidate.mimeData as em.BinaryMimeData).data;
              } else if (candidate.mimeData is em.TextMimeData) {
                data = Uint8List.fromList(utf8.encode((candidate.mimeData as em.TextMimeData).text));
              }
            }
            data ??= candidate.decodeContentBinary();
          }
          data ??= message.decodeContentBinary();
        }

        // Eğer veri hala boş ise, tekil BODY.PEEK[$partId] ile tekrar dene:
        if ((data == null || data.isEmpty) && partId.isNotEmpty) {
          try {
            final fbResult = await _requireClient.uidFetchMessages(
              sequence,
              '(BODY.PEEK[$partId])',
              responseTimeout: _attachmentResponseTimeout,
            );
            final fbMsg = fbResult.messages.firstOrNull;
            if (fbMsg != null) {
              final fbPart = fbMsg.getPart(partId) ??
                  (fbMsg.parts?.isNotEmpty == true ? fbMsg.parts!.first : null);
              if (fbPart != null) {
                if (isEmlOrRfc822 && !isBase64) {
                  if (fbPart.mimeData is em.BinaryMimeData) {
                    final raw = (fbPart.mimeData as em.BinaryMimeData).data;
                    if (raw.isNotEmpty) data = raw;
                  } else if (fbPart.mimeData is em.TextMimeData) {
                    final raw = (fbPart.mimeData as em.TextMimeData).text;
                    if (raw.isNotEmpty) data = Uint8List.fromList(utf8.encode(raw));
                  }
                }
                data ??= fbPart.decodeContentBinary();
              } else {
                data = fbMsg.decodeContentBinary();
              }
            }
          } catch (_) {}
        }

        if (data == null || data.isEmpty) {
          throw const ImapServiceException('Ek içeriği çözülemedi');
        }

        // EML / RFC 822 eklerinde ikili bayt çözümlemesi (ensureBinaryDecoded) yapılmaz,
        // çünkü EML dosyası zaten RFC 822 metin/MIME akışıdır.
        if (isEmlOrRfc822) {
          return data;
        }

        return AttachmentFiles.ensureBinaryDecoded(data);
      }, timeout: _attachmentResponseTimeout + _outerSlack);

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
    String? sourceEncodedPath,
    String? targetEncodedPath,
  }) => _guard(() async {
    if (uids.isEmpty) return;
    final sequence = em.MessageSequence.fromIds(uids, isUid: true);
    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    String wirePath(String path, String? encoded) =>
        (encoded != null && encoded.isNotEmpty)
        ? encoded
        : em.Mailbox.encode(path, separator);

    // `_selectedPath` SELECT'te sunucuya giden (kodlanmış) yolu tutar; ham yolla
    // karşılaştırmak ASCII olmayan adlarda hep "farklı" çıkıp yanlış yolla
    // yeniden SELECT ederdi.
    if (sourcePath != null) {
      final wireSource = wirePath(sourcePath, sourceEncodedPath);
      if (_selectedPath != wireSource) {
        await client.selectMailboxByPath(wireSource);
        _selectedPath = wireSource;
      }
    }
    final wireTarget = wirePath(targetPath, targetEncodedPath);
    if (client.serverInfo.supportsMove) {
      await client.uidMove(sequence, targetMailboxPath: wireTarget);
      return;
    }
    // MOVE desteklenmiyorsa: KOPYALA + \Deleted + EXPUNGE
    await client.uidCopy(sequence, targetMailboxPath: wireTarget);
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
    String? encodedPath,
    List<String> flags = const [],
  }) => _guard(() async {
    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    final effectivePath = (encodedPath != null && encodedPath.isNotEmpty)
        ? encodedPath
        : em.Mailbox.encode(targetPath, separator);

    try {
      final result = await client.appendMessageText(
        mimeSource,
        targetMailboxPath: effectivePath,
        flags: flags.isEmpty ? null : flags,
        responseTimeout: _appendResponseTimeout,
      );
      return result.responseCodeAppendUid?.targetSequence.toList().firstOrNull;
    } on em.ImapException catch (error) {
      if (effectivePath != targetPath &&
          (error.message?.toUpperCase().contains('NONEXISTENT') ?? false)) {
        final result = await client.appendMessageText(
          mimeSource,
          targetMailboxPath: targetPath,
          flags: flags.isEmpty ? null : flags,
          responseTimeout: _appendResponseTimeout,
        );
        return result.responseCodeAppendUid?.targetSequence.toList().firstOrNull;
      }
      rethrow;
    }
  }, timeout: _appendResponseTimeout + _outerSlack);

  @override
  Future<Result<String>> fetchRawSource(int uid, {int maxChars = 200000}) =>
      _guard(() async {
        final result = await _requireClient.uidFetchMessages(
          em.MessageSequence.fromId(uid, isUid: true),
          '(UID BODY.PEEK[])',
          responseTimeout: _bodyResponseTimeout,
        );
        final message = result.messages.firstOrNull;
        if (message == null) throw const MessageNotFoundException();
        final source = message.mimeData?.toString() ?? message.renderMessage();
        return source.length > maxChars ? source.substring(0, maxChars) : source;
      });

  @override
  Future<Result<bool>> existsByMessageId({
    required String path,
    String? encodedPath,
    required String messageId,
  }) => _guard(() async {
    final bare = messageId.trim().replaceAll(RegExp(r'^<|>$'), '');
    // SEARCH kriterini bozacak karakterler; geçerli bir Message-ID'de olmaz.
    if (bare.isEmpty || bare.contains(RegExp(r'["\\\r\n]'))) return false;

    final client = _requireClient;
    final separator = client.serverInfo.pathSeparator ?? '/';
    final wirePath = (encodedPath != null && encodedPath.isNotEmpty)
        ? encodedPath
        : em.Mailbox.encode(path, separator);
    if (_selectedPath != wirePath) {
      await client.selectMailboxByPath(wirePath);
      _selectedPath = wirePath;
    }

    // HEADER araması alt dize eşleşmesidir; parantezsiz arama her iki biçimi
    // de yakalar.
    final result = await client.uidSearchMessages(
      searchCriteria: 'HEADER Message-ID "$bare"',
    );
    return (result.matchingSequence?.toList() ?? const <int>[]).isNotEmpty;
  });

  @override
  Future<Result<void>> createMailbox(String path) => _guard(() async {
    await _requireClient.createMailbox(path);
  });

  @override
  Future<Result<void>> unsubscribeMailbox(String encodedPath) =>
      _guard(() async {
        await _requireClient.unsubscribeMailbox(
          em.Mailbox(
            encodedName: encodedPath,
            encodedPath: encodedPath,
            flags: const [],
            pathSeparator: '/',
          ),
        );
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
  Future<Result<void>> noop({Duration? timeout}) => _guard(() async {
    await _requireClient.noop();
  }, timeout: timeout ?? _commandTimeout);

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
  ///
  /// [timeout], komutun toplam süresini sınırlar. Süre dolarsa bağlantı
  /// KAPATILIR: yanıt sonradan gelirse bir sonraki komutun yanıtıyla karışır
  /// ve protokol durumu bozulurdu. Kapalı bağlantı bir sonraki işlemde
  /// (bkz. `MailConnection.ensureConnected`) temiz biçimde yeniden kurulur.
  Future<Result<T>> _guard<T>(
    Future<T> Function() action, {
    Duration timeout = _commandTimeout,
  }) => _lock.synchronized(() async {
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
      return Ok(await action().timeout(timeout));
    } on TimeoutException catch (error, stack) {
      await _teardown(graceful: false);
      return Err(_mapError(error, stack));
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
    if (error is MessageNotFoundException) {
      return const MessageNotFoundFailure();
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
