import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../domain/models/push_stub.dart';
import 'providers.dart';

/// Bekleyen [PushStub] listesi (yalnızca iOS'ta dolar).
class PushStubsController extends Notifier<List<PushStub>> {
  @override
  List<PushStub> build() => const [];

  /// Native depodan okur; zaten eşitlenmiş olanları depodan siler. Uygulama
  /// açılırken/öne gelirken, eşitlemeden ÖNCE çağrılır.
  Future<void> refresh() async {
    final stubs = await ref.read(notificationServiceProvider).takePushStubs();
    if (!ref.mounted) return;
    state = await _unresolved(stubs, purge: true);
  }

  /// Bir eşitleme turundan sonra gerçek iletisi gelen kayıtları düşürür.
  Future<void> reconcile() async {
    if (state.isEmpty) return;
    final remaining = await _unresolved(state, purge: true);
    if (!ref.mounted) return;
    if (remaining.length != state.length) state = remaining;
  }

  /// Kayıtları sıfırlar (çıkış yapıldığında).
  void clear() => state = const [];

  /// Gerçek iletisi yerelde olan ya da eşitlemenin zaten geçtiği (uid <
  /// `uidNext`; ileti başka cihazdan silinmiş/taşınmış olabilir) kayıtlar
  /// çözülmüş sayılır.
  Future<List<PushStub>> _unresolved(
    List<PushStub> stubs, {
    required bool purge,
  }) async {
    if (stubs.isEmpty) return const [];
    final db = ref.read(databaseProvider);
    final remaining = <PushStub>[];
    final resolved = <int, List<int>>{};
    final inboxes = <int, MailboxRow?>{};

    for (final stub in stubs) {
      final inbox = inboxes[stub.accountId] ??= await db.mailboxBySpecialUse(
        stub.accountId,
        SpecialUse.inbox,
      );
      var done = false;
      if (inbox != null) {
        final nextUid = inbox.uidNext;
        done =
            (nextUid != null && stub.uid < nextUid) ||
            await db.messageByUid(inbox.id, stub.uid) != null;
      }
      if (done) {
        resolved.putIfAbsent(stub.accountId, () => []).add(stub.uid);
      } else {
        remaining.add(stub);
      }
    }

    if (purge) {
      final service = ref.read(notificationServiceProvider);
      for (final entry in resolved.entries) {
        unawaited(service.removePushStubs(entry.key, entry.value));
      }
    }
    return remaining;
  }
}

final pushStubsProvider =
    NotifierProvider<PushStubsController, List<PushStub>>(
      PushStubsController.new,
    );
