import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../app/providers.dart';
import '../../../data/repositories/mail_repository.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'compose_screen.dart';
import 'send_feedback.dart';

/// Yazma ekranının TEK giriş noktası: Gelen Kutusu, arama, kişiler ve ileti
/// detayı hep bunu çağırır — hiçbiri `ComposeScreen`'i kendi başına açmaz.
///
/// Ekran kapandığında sonuca göre altta kısa bir bildirim gösterilir (bkz.
/// [KaydetNotice]):
/// - İçerikli bir taslakla kapandıysa (geri tuşu/X, bkz.
///   `ComposeScreen._closeScreen`) "kaydedildi"; kullanıcı pişman olursa
///   yanındaki "Sil" eylemiyle taslağı silebilir.
/// - İleti gönderildiyse "gönderiliyor", sonra gerçek sonuca göre
///   "gönderildi" ya da "gönderilemedi" (bkz. [SendFeedback]).
/// - Boş bırakılan iletide bildirim çıkmaz.
///
/// [noticeBottomInset], çağıran ekranın altında bildirimin kapatmaması
/// gereken bir öğe varsa (FAB, alt eylem çubuğu) onun yüksekliğidir — bkz.
/// [KaydetNotice.show].
///
/// Bildirim çağıran ekrana bırakılmadı: rota kapanana kadar o ekranın
/// `BuildContext`i ağaçtan çıkmış olabilir ve `context.mounted` denetimine
/// takılan bildirim sessizce hiç görünmüyordu (bkz. `KaydetDepthCoverEffect`).
/// Bu yüzden gereken her şey — kök `Overlay`, repository — rota açılmadan
/// ÖNCE yakalanır; ikisi de hiçbir ekranın ömrüne bağlı değildir.
Future<void> openCompose(
  BuildContext context,
  WidgetRef ref, {
  int? draftId,
  int? replyToId,
  ComposeMode mode = ComposeMode.newMessage,
  String? initialTo,
  bool fullscreenDialog = false,
  KaydetTransitionStyle transitionStyle = KaydetTransitionStyle.compose,
  double noticeBottomInset = 0,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final repository = ref.read(mailRepositoryProvider);

  // Önceki bir oturumdan kalan bildirimin "Sil" eylemi, şimdi açılan (ya da
  // düzenlenmek üzere açılan) taslağı da hedef alabilir.
  KaydetNotice.dismiss();

  final outcome = await context.pushScreen<ComposeOutcome>(
    ComposeScreen(
      draftId: draftId,
      replyToId: replyToId,
      mode: mode,
      initialTo: initialTo,
    ),
    fullscreenDialog: fullscreenDialog,
    transitionStyle: transitionStyle,
  );
  _announceOutcome(overlay, repository, outcome, noticeBottomInset);
}

/// Widget ağacının dışından — bildirimdeki "Yanıtla" eylemi gibi — yazma
/// ekranını açar (bkz. `NotificationNavigator`).
///
/// Elinde bir `BuildContext`/`WidgetRef` olmayan çağıranlar için [openCompose]
/// ile aynı akıştır: kök `Navigator`ın kendisi verilir, kök `Overlay` ondan
/// alınır.
Future<void> openComposeFromNavigator(
  NavigatorState navigator, {
  required MailRepository repository,
  int? replyToId,
  ComposeMode mode = ComposeMode.newMessage,
}) async {
  final overlay = navigator.overlay;
  KaydetNotice.dismiss();

  final outcome = await navigator.push<ComposeOutcome>(
    KaydetRoute<ComposeOutcome>(
      builder: (_) => ComposeScreen(replyToId: replyToId, mode: mode),
      transitionStyle: KaydetTransitionStyle.compose,
    ),
  );
  if (overlay == null) return;
  _announceOutcome(overlay, repository, outcome, 0);
}

void _announceOutcome(
  OverlayState overlay,
  MailRepository repository,
  ComposeOutcome? outcome,
  double bottomInset,
) {
  if (!overlay.mounted) return;

  switch (outcome) {
    case ComposeDraftSaved(:final draftId):
      KaydetNotice.show(
        overlay,
        message: 'İleti Taslaklara kaydedildi.',
        actionLabel: 'Sil',
        destructiveAction: true,
        bottomInset: bottomInset,
        onAction: () => _confirmDeleteDraft(
          () => repository.deletePermanently([draftId]),
        ),
      );
    case ComposeSendQueued(:final messageId):
      SendFeedback.track(
        overlay,
        repository.watchOutboxState(messageId),
        bottomInset: bottomInset,
      );
    case null:
      break;
  }
}

/// Taslaklar sunucuya hiç gitmemiştir (bkz. `deleteWithConfirmation`), bu
/// yüzden bu silme de kalıcıdır ve ayrı bir onay ister.
///
/// Bildirim kendisini açan ekrandan uzun yaşayabilir; diyalog bu yüzden o
/// ekranın değil kök gezginin bağlamında açılır.
Future<void> _confirmDeleteDraft(Future<void> Function() delete) async {
  final navigatorContext = rootNavigatorKey.currentContext;
  if (navigatorContext == null) return;

  final confirmed = await showDialog<bool>(
    context: navigatorContext,
    builder: (context) => AlertDialog(
      title: const Text('Taslağı silmek istediğinize emin misiniz?'),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Hayır',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: 'Evet',
          onConfirm: () => Navigator.of(context).pop(true),
          destructive: true,
        ),
      ],
    ),
  );
  if (confirmed == true) await delete();
}
