import Flutter
import Foundation

/// Share Extension'ın App Group gelen kutusuna bıraktığı paylaşımları Flutter'a
/// açan köprü (Dart karşılığı: `ShareIntakeService`, kanal adı aynı).
///
/// **Sözleşme:** paylaşım Flutter'a İTİLMEZ; uzantı dosyaları ve manifesti diske
/// yazar, ana uygulama açıldığında/öne geldiğinde Flutter `takePendingShares`
/// ile ÇEKER (bkz. `ShareNavigator`: soğuk başlangıç + `resumed`). Uzantı ile
/// ana uygulama farklı süreçler ve farklı yaşam döngüleri olduğundan, gelen
/// kutusunun kendisi (`ShareInbox`) tek ortak doğruluk kaynağıdır — Flutter
/// motoru hazır olmasa bile hiçbir paylaşım kaybolmaz.
///
/// Android'deki `ShareChannel.kt` ile aynı yöntem adları/sözleşme; iOS'ta
/// `onShareReceived` dürtmesi YOKTUR: uzantı ana uygulamayı açtığında zaten
/// yaşam döngüsü `resumed` olur.
final class ShareChannel {
    static let channelName = "tr.com.pazarlik.kaydet/share"

    private let channel: FlutterMethodChannel

    /// Tüm dosya G/Ç'si ana iş parçacığı dışında, sırayla yapılır.
    private let queue = DispatchQueue(label: "tr.com.pazarlik.kaydet.share", qos: .userInitiated)

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: ShareChannel.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            self.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "takePendingShares":
            run(result) { root in
                // Gelen kutusu ilk paylaşımdan önce hiç oluşmamış olabilir.
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let reply: [String: Any] = [
                    "root": root.path,
                    "payloads": ShareInbox.readPending(root: root),
                ]
                return reply
            }

        case "acknowledgeShare":
            let id = (call.arguments as? [String: Any])?["id"] as? String
            run(result) { root in
                ShareInbox.acknowledge(id: id, root: root)
                return nil
            }

        case "discardShare":
            let id = (call.arguments as? [String: Any])?["id"] as? String
            run(result) { root in
                ShareInbox.discard(id: id, root: root)
                return nil
            }

        case "inboxRoot":
            // App Group erişilemiyorsa `nil`: süpürücü sessizce atlanır.
            result(ShareInbox.rootURL()?.path)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// İşi sıraya koyar ve sonucu ana iş parçacığında döner. App Group
    /// erişilemiyorsa (entitlement/portal yapılandırması eksik) çökmek yerine
    /// Dart'a hata döner; Dart bunu yutar ve paylaşım yokmuş gibi davranır.
    private func run(_ result: @escaping FlutterResult, work: @escaping (URL) -> Any?) {
        guard let root = ShareInbox.rootURL() else {
            result(FlutterError(code: "app_group_unavailable", message: "App Group erişilemiyor", details: nil))
            return
        }
        queue.async {
            let value = work(root)
            DispatchQueue.main.async { result(value) }
        }
    }
}
