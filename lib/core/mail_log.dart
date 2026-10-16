import 'package:flutter/foundation.dart';

/// Posta işlem yaşam döngüsünün geliştirme günlüğü.
///
/// Bir kullanıcı eyleminin hangi katmanlardan geçtiğini tek akışta izlemek
/// içindir; örneğin silme:
///
/// ```
/// [USE CASE] delete ids=[3]
/// [REPOSITORY] enqueue move INBOX -> INBOX.Trash uids=[41]
/// [DRIFT] remove local rows ids=[3]
/// [REMOTE/IMAP] move SUCCESS INBOX -> INBOX.Trash uids=[41]
/// [DRIFT] complete op 17
/// [SYNC] refresh target INBOX.Trash
/// [RECONCILIATION] INBOX.Trash new=1 deleted=0 changed=0
/// ```
///
/// Yalnızca debug derlemelerinde yazar; release'te maliyeti yoktur ve posta
/// içeriği (konu, adres, gövde) ASLA günlüğe girmez.
class MailLog {
  const MailLog._();

  /// Testlerin satırları yakalayabilmesi için değiştirilebilir çıkış.
  @visibleForTesting
  static void Function(String line)? sink;

  static void ui(String message) => _write('UI', message);
  static void useCase(String message) => _write('USE CASE', message);
  static void repository(String message) => _write('REPOSITORY', message);
  static void remote(String message) => _write('REMOTE/IMAP', message);
  static void drift(String message) => _write('DRIFT', message);
  static void sync(String message) => _write('SYNC', message);
  static void reconcile(String message) => _write('RECONCILIATION', message);

  // Bildirimden ileti açma yaşam döngüsü (bkz. `NotificationNavigator`).
  static void notification(String message) => _write('NOTIFICATION', message);
  static void app(String message) => _write('APP', message);
  static void auth(String message) => _write('AUTH', message);
  static void database(String message) => _write('DATABASE', message);
  static void target(String message) => _write('TARGET', message);
  static void navigation(String message) => _write('NAVIGATION', message);

  static void _write(String tag, String message) {
    final line = '[$tag] $message';
    final capture = sink;
    if (capture != null) {
      capture(line);
      return;
    }
    if (kDebugMode) debugPrint(line);
  }
}
