import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../domain/models/mail_models.dart';
import '../../core/widgets/kaydet_notice.dart';

/// Gönderilen iletinin sonucunu kullanıcıya bildirir: önce "gönderiliyor",
/// sonra — gerçek sonuç belli olunca — "gönderildi" ya da "gönderilemedi".
///
/// Gönderim kuyruğa alınıp arka planda yapılır (bkz. `MailRepository.queueSend`),
/// bu yüzden yazma ekranı kapandığında ileti henüz gitmemiş olabilir. Yalnızca
/// "gönderiliyor" diyip kaybolmak kullanıcıyı sonuçtan habersiz bırakırdı.
///
/// Bildirimler kök `Overlay`de yaşar (bkz. [KaydetNotice]); çağıran ekranın
/// ağaçta kalmasına bağlı değildir.
abstract final class SendFeedback {
  static const String sendingMessage = 'İleti gönderiliyor…';
  static const String sentMessage = 'İleti gönderildi.';
  static const String failedMessage =
      'İleti gönderilemedi. Gönderilenler klasöründen yeniden deneyebilirsiniz.';
  static const String waitingMessage =
      'İleti henüz gönderilemedi; bağlantı sağlanınca otomatik gönderilecek.';

  /// Sonucu bu süre boyunca beklenir. Aşılırsa (ağ yok, sunucu yavaş) durum
  /// dürüstçe söylenir ve izleme bırakılır: dakikalar sonra, kullanıcı başka
  /// bir işteyken çıkan bir "gönderildi" bildirimi gürültü olurdu.
  static const Duration defaultPatience = Duration(seconds: 20);

  /// [states] iletinin gönderim durumudur (bkz. `MailRepository.watchOutboxState`).
  ///
  /// [bottomInset], çağıran ekranın altındaki öğenin (ör. "Yeni" düğmesi)
  /// yüksekliğidir — bkz. [KaydetNotice.show].
  static void track(
    OverlayState overlay,
    Stream<OutboxState?> states, {
    double bottomInset = 0,
    Duration patience = defaultPatience,
  }) {
    void notify(String message) {
      if (!overlay.mounted) return;
      KaydetNotice.show(overlay, message: message, bottomInset: bottomInset);
    }

    // "Gönderiliyor" bildirimi sonuç gelene kadar açık kalır; sonuç onu
    // yumuşakça yenisiyle değiştirir. Süre, bekleme sınırının biraz üstündedir
    // — bir aksilikte bile ekranda sonsuza dek kalmaz.
    if (overlay.mounted) {
      KaydetNotice.show(
        overlay,
        message: sendingMessage,
        bottomInset: bottomInset,
        duration: patience + const Duration(seconds: 5),
      );
    }

    late final StreamSubscription<OutboxState?> subscription;
    Timer? timer;

    void finish(String? message) {
      timer?.cancel();
      unawaited(subscription.cancel());
      if (message != null) {
        notify(message);
      } else {
        KaydetNotice.dismiss();
      }
    }

    timer = Timer(patience, () => finish(waitingMessage));
    subscription = states.listen(
      (state) {
        switch (state) {
          case OutboxState.sent:
            finish(sentMessage);
          case OutboxState.failed:
            finish(failedMessage);
          case null:
            // İleti kullanıcı tarafından silindi: söylenecek bir sonuç yok.
            finish(null);
          case OutboxState.none:
          case OutboxState.queued:
          case OutboxState.sending:
            break;
        }
      },
      onError: (Object _) => finish(null),
    );
  }
}
