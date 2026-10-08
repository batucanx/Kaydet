import UserNotifications

/// Notification Service Extension: `mutable-content: 1` taşıyan her uzak
/// bildirimde (uygulama arka planda, kapalı ya da kullanıcı tarafından
/// sonlandırılmış olsa bile) çalışır ve ileti özetini App Group'a yazar. Ana
/// uygulama açılınca listeyi bu kayıtlardan hemen doldurur
/// (bkz. `PushStubStore`, Dart `PushStubs`).
///
/// Bildirimin içeriğini DEĞİŞTİRMEZ; yalnızca yan etki olarak kaydeder. Hata
/// olursa bildirim yine olduğu gibi gösterilir.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = request.content
        if let root = PushStubStore.rootURL() {
            PushStubStore.record(
                userInfo: content.userInfo,
                title: content.title,
                body: content.body,
                root: root
            )
        }
        contentHandler(content)
    }

    /// Süre dolarsa (~30 sn) iOS bu yöntemi çağırır; içerik değiştirilmediği
    /// için özgün bildirim olduğu gibi teslim edilir.
    override func serviceExtensionTimeWillExpire() {}
}
