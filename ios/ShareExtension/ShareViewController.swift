import UIKit

/// Sistem Share Sheet'inde "Kaydet" olarak görünen paylaşım uzantısı.
///
/// **Akış:** Fotoğraflar/Dosyalar → Paylaş → Kaydet
/// 1. `ShareItemIngester`, paylaşılan öğeleri App Group gelen kutusuna
///    (`ShareInbox`) kopyalar ve manifesti yazar.
/// 2. Uzantı, `kaydetshare://open` ile ana uygulamayı uyandırır (URL veri
///    taşımaz) ve kendini kapatır.
/// 3. Ana uygulama öne gelince Flutter, bekleyen paylaşımı gelen kutusundan
///    ÇEKER ve Yeni İleti'yi ekli olarak açar (bkz. `ShareNavigator`).
///
/// Uzantı ana uygulamadan BAĞIMSIZ bir süreçtir; ana uygulama kapalı, arka
/// planda ya da açıkken aynı şekilde çalışır ve Flutter'a hiç bağlı değildir.
/// Ana uygulama açılamazsa bile dosyalar App Group'ta bekler ve uygulama bir
/// sonraki açılışta (24 saat içinde) teslim alır.
///
/// Arayüz bilerek minimaldir (spinner + kısa metin): kullanıcı, alıcı/konu/gövdeyi
/// ana uygulamadaki Yeni İleti ekranında doldurur.
final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()

    private var task: Task<Void, Never>?

    /// Uzantı normal biçimde tamamlandı ya da iptal edildi; `viewDidDisappear`
    /// bunu "kullanıcı vazgeçti"den ayırmak için kullanır.
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Kaydet'e ekleniyor…"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard task == nil else { return }

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        task = Task { [weak self] in
            let outcome = await ShareItemIngester.ingest(items: items)
            await MainActor.run { self?.finish(with: outcome) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Kullanıcı sayfayı aşağı kaydırıp vazgeçtiyse süren kopyalama durdurulur
        // ve yarım paylaşım dizini silinir (bkz. `ShareItemIngester`).
        if !finished { task?.cancel() }
    }

    // MARK: - Sonuç

    private func finish(with outcome: ShareItemIngester.Outcome) {
        finished = true
        spinner.stopAnimating()

        switch outcome {
        case .delivered:
            openHostApp()
            // Açma isteğinin sisteme ulaşması için kısa bir süre tanınır.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }

        case .failed(let message):
            let alert = UIAlertController(title: "Kaydet", message: message, preferredStyle: .alert)
            alert.addAction(
                UIAlertAction(title: "Tamam", style: .default) { [weak self] _ in
                    self?.extensionContext?.cancelRequest(
                        withError: NSError(domain: "tr.com.pazarlik.kaydet.share", code: 1)
                    )
                }
            )
            present(alert, animated: true)

        case .cancelled:
            extensionContext?.cancelRequest(withError: NSError(domain: "tr.com.pazarlik.kaydet.share", code: 2))
        }
    }

    // MARK: - Ana uygulamayı açma

    /// Paylaşım uzantıları ana uygulamayı açmak için resmî bir API sunmaz
    /// (`NSExtensionContext.open(_:)` yalnızca Today widget'ları için çalışır).
    /// Yaygın çözüm: yanıtlayıcı zincirinde `UIApplication` örneğini bulup ona
    /// `open(_:options:completionHandler:)` göndermek.
    ///
    /// `UIApplication.open` uygulama-uzantısı API'sinde "kullanılamaz" işaretlidir;
    /// derleme hatası vermemesi için seçici çalışma zamanında çağrılır. iOS 18'de
    /// eski `openURL:` çalışmaz, bu yüzden yalnızca yeni imza kullanılır.
    ///
    /// Açılamazsa dosyalar yine de App Group'ta bekler ve kullanıcı Kaydet'i
    /// elle açtığında teslim alınır — veri kaybolmaz.
    private func openHostApp() {
        guard let url = URL(string: "\(ShareInbox.urlScheme)://open") else { return }

        typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")

        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let implementation = current.method(for: selector) {
                let openURL = unsafeBitCast(implementation, to: OpenFunction.self)
                openURL(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
