import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/mail_filter_repository.dart';
import '../domain/models/mail_filter.dart';
import 'providers.dart';

/// Gelen e-posta filtreleri deposu. Arayüzden yapılan her değişiklik (ekle, düzenle, aç/kapat, sırala, sil) ayar belgesinin
/// yakında (2 sn gecikmeyle, diğer ayarlar gibi) web ve diğer cihazlarla eşitlenmesini ister.
final mailFilterRepositoryProvider = Provider<MailFilterRepository>(
  (ref) => MailFilterRepository(
    database: ref.watch(databaseProvider),
    onChanged: (accountId) =>
        ref.read(settingsSyncServiceProvider).schedule(accountId),
  ),
);

/// Etkin hesabın filtreleri, çalışma sırasıyla.
final mailFiltersProvider = StreamProvider<List<MailFilter>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <MailFilter>[]);
  return ref.watch(mailFilterRepositoryProvider).watch(accountId);
});
