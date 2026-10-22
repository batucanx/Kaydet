import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mail_log.dart';
import '../data/services/notification_service.dart';

/// Bir bildirime dokunmanın uygulamadan istediği şey: "şu iletiyi aç" ya da
/// "şu iletiyi yanıtla".
///
/// Bildirim dokunuşu, normal uygulama açılışından (Splash → Gelen Kutusu)
/// AYRI ve ÖNCELİKLİ bir gezinme niyetidir. Niyet dokunuş anında yakalanır ve
/// uygulama başlatma/eşitleme ne kadar sürerse sürsün kaybolmaz (bkz.
/// [PendingNotificationIntents]); hedef ileti çözülene dek varsayılan rotaya
/// geçilmez.
class NotificationIntent {
  const NotificationIntent._({
    required this.key,
    required this.kind,
    required this.dedupeTtl,
    this.messageRowId,
    this.accountId,
    this.uid,
    this.folderPath,
    this.uidValidity,
    this.messageIdHeader,
  });

  /// Yerel bildirim (Android ve iOS yerel): yük yerel veritabanı kimliğidir.
  factory NotificationIntent.local(NotificationTap tap) => NotificationIntent._(
    key: 'local:${tap.kind.name}:${tap.messageId}',
    kind: tap.kind,
    // Yerel yükte benzersiz bildirim kimliği yoktur: soğuk açılışta aynı
    // dokunuşu hem `appLaunchDetails` hem eklenti geri çağrısı bildirebilir.
    // Kısa pencere bunu eler; kullanıcının sonradan yaptığı gerçek ikinci
    // dokunuşu engellemez.
    dedupeTtl: const Duration(seconds: 5),
    messageRowId: tap.messageId,
  );

  /// iOS uzak (APNs) bildirim: yük sunucudaki tanımlayıcıları taşır.
  factory NotificationIntent.remote(RemoteMailTarget target) {
    final eventId = target.eventId;
    return NotificationIntent._(
      key: eventId != null
          ? 'apns:$eventId'
          : 'apns:${target.accountId}:${target.uid}',
      kind: NotificationTapKind.open,
      // Sistem kimliği benzersizdir; kimliksiz yedek anahtar için kısa pencere.
      dedupeTtl: eventId != null
          ? const Duration(hours: 24)
          : const Duration(seconds: 5),
      accountId: target.accountId,
      uid: target.uid,
      folderPath: target.folder,
      uidValidity: target.uidValidity,
      messageIdHeader: target.messageId,
    );
  }

  /// Tekilleştirme anahtarı: aynı anahtar, penceresi dolmadan ikinci kez
  /// işlenmez.
  final String key;
  final NotificationTapKind kind;
  final Duration dedupeTtl;

  /// Yerel bildirim: `messages.id`. Doluysa sunucu tanımlayıcıları boştur.
  final int? messageRowId;

  /// Uzak bildirim: hesap (`null` ise etkin hesap), klasör içi IMAP UID'si,
  /// klasör, o klasörün UIDVALIDITY'si ve `Message-ID` başlığı.
  final int? accountId;
  final int? uid;
  final String? folderPath;
  final int? uidValidity;
  final String? messageIdHeader;

  bool get isLocal => messageRowId != null;

  /// Günlükte kullanılabilecek, posta içeriği taşımayan kısa özet.
  String get summary => isLocal
      ? '${kind.name} row=$messageRowId'
      : '${kind.name} account=$accountId folder=${folderPath ?? 'INBOX'} '
            'uid=$uid uidValidity=$uidValidity '
            'messageId=${messageIdHeader != null}';
}

/// Henüz işlenmemiş bildirim niyeti için SÜREÇ ÖMÜRLÜ depo.
///
/// Bilerek bir Riverpod sağlayıcısı DEĞİLDİR: sağlayıcılar yeniden kurulabilir,
/// dispose edilebilir ya da henüz oluşturulmamış olabilir; niyet bunlardan
/// bağımsız yaşamalı ve `runApp`ten ÖNCE yakalanabilmelidir (bkz.
/// [NotificationIntake]).
///
/// Yaşam döngüsü: yakala ([capture]) → tüket ([take]) → gezin → bitti.
/// [take] niyeti anında "tüketildi" işaretler; böylece aynı bildirimin ikinci
/// kez gelmesi (soğuk açılışta çift teslim, tekrarlanan olay) ekranı ikinci
/// kez açmaz.
class PendingNotificationIntents {
  PendingNotificationIntents();

  /// Uygulama genelindeki depo.
  static final PendingNotificationIntents instance =
      PendingNotificationIntents();

  /// Tüketilmiş anahtarların bellekte tutulacağı en çok sayı.
  static const int _maxRemembered = 64;

  NotificationIntent? _pending;
  final Map<String, DateTime> _consumedUntil = {};
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );

  /// Bekleyen yeni bir niyet yakalandığında uyarır.
  Stream<void> get changes => _changes.stream;

  NotificationIntent? get pending => _pending;

  bool _isRecent(String key) {
    final until = _consumedUntil[key];
    return until != null && DateTime.now().isBefore(until);
  }

  /// Niyeti bekletir. Aynı bildirim zaten bekliyorsa ya da yakın zamanda
  /// işlendiyse `false` döner. Daha yeni bir niyet eskisinin yerine geçer:
  /// kullanıcının son dokunduğu bildirim kazanır.
  bool capture(NotificationIntent intent) {
    if (_pending?.key == intent.key) {
      MailLog.notification('duplicate ignored (already pending) ${intent.key}');
      return false;
    }
    if (_isRecent(intent.key)) {
      MailLog.notification('duplicate ignored (already handled) ${intent.key}');
      return false;
    }
    _pending = intent;
    MailLog.notification('target captured ${intent.summary}');
    _changes.add(null);
    return true;
  }

  /// Bekleyen niyeti alır ve tüketilmiş işaretler; yoksa `null`.
  NotificationIntent? take() {
    final intent = _pending;
    if (intent == null) return null;
    _pending = null;
    _consumedUntil[intent.key] = DateTime.now().add(intent.dedupeTtl);
    if (_consumedUntil.length > _maxRemembered) {
      final now = DateTime.now();
      _consumedUntil.removeWhere((_, until) => now.isAfter(until));
      while (_consumedUntil.length > _maxRemembered) {
        _consumedUntil.remove(_consumedUntil.keys.first);
      }
    }
    return intent;
  }
}

/// Bildirim dokunuşlarını (yerel ve APNs) kaynaklarından alıp
/// [PendingNotificationIntents]'e yazar.
///
/// `main()` içinde `runApp`ten ÖNCE başlatılır: soğuk açılışta dokunuş bilgisi
/// ilk kare çizilmeden, sağlayıcılar/veritabanı/eşitleme başlamadan yakalanır.
/// Tüm kaynaklar (soğuk başlangıç, arka plandan dönüş, ön plan) aynı depoya
/// yazar; hedef çözümü tek yoldur.
class NotificationIntake {
  NotificationIntake._(this._service, this._store);

  final NotificationService _service;
  final PendingNotificationIntents _store;

  static NotificationIntake? _started;
  StreamSubscription<NotificationTap>? _tapSub;
  StreamSubscription<void>? _remoteSub;

  /// Dinleyicileri kurar (süreç başına bir kez) ve soğuk başlangıçta bekleyen
  /// dokunuşu hemen çeker.
  static Future<NotificationIntake> start(
    NotificationService service, {
    PendingNotificationIntents? store,
  }) async {
    final existing = _started;
    if (existing != null && store == null) return existing;
    final intake = NotificationIntake._(
      service,
      store ?? PendingNotificationIntents.instance,
    );
    if (store == null) _started = intake;
    intake._listen();
    await intake.pull();
    return intake;
  }

  void _listen() {
    _tapSub = NotificationService.taps.listen((tap) {
      MailLog.notification('tapped (local) ${tap.kind.name}');
      _store.capture(NotificationIntent.local(tap));
    });
    _remoteSub = NotificationService.mailTaps.listen((_) {
      MailLog.notification('tapped (remote)');
      unawaited(_pullRemote());
    });
  }

  /// Süreç açılırken bekleyen tüm dokunuşları (APNs ve yerel) depoya alır.
  Future<void> pull() async {
    await (
      _pullRemote(),
      _pullLaunchDetails(),
    ).wait;
  }

  Future<void> _pullRemote() async {
    final target = await _service.takePendingMailOpen();
    if (target == null) return;
    _store.capture(NotificationIntent.remote(target));
  }

  Future<void> _pullLaunchDetails() async {
    try {
      final details = await _service.appLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return;
      final tap = NotificationService.tapFromResponse(
        details!.notificationResponse,
      );
      if (tap == null) return;
      MailLog.notification('launched by local notification ${tap.kind.name}');
      _store.capture(NotificationIntent.local(tap));
    } on Object catch (error) {
      MailLog.notification('launch details unavailable: $error');
    }
  }

  Future<void> dispose() async {
    await _tapSub?.cancel();
    await _remoteSub?.cancel();
    if (identical(_started, this)) _started = null;
  }
}

/// [PendingNotificationIntents.instance]; testler kendi deposunu verir.
final pendingNotificationIntentsProvider =
    Provider<PendingNotificationIntents>(
      (ref) => PendingNotificationIntents.instance,
    );
