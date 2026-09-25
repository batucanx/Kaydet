package tr.com.pazarlik.kaydet

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Sistem "Paylaş" menüsünden (Galeri, Dosyalar…) gelen `ACTION_SEND` /
 * `ACTION_SEND_MULTIPLE` Intent'lerini [ShareChannel]'a iletir.
 *
 * Üç durum da aynı yoldan geçer:
 * - **Soğuk başlangıç:** `onCreate`, `savedInstanceState == null`.
 * - **Sıcak/arka plan:** `singleTask` sayesinde tek Activity örneğine
 *   `onNewIntent` ile gelir (bkz. AndroidManifest.xml'deki `launchMode`).
 * - **Yeniden yaratılma:** `savedInstanceState != null` ise `getIntent()` yeni
 *   bir paylaşım DEĞİL, ilk başlatan Intent'in yeniden teslimidir — atlanır.
 */
class MainActivity : FlutterActivity() {
    private var shareChannel: ShareChannel? = null

    // `super.onCreate` içinde, `onCreate`in kalanından ÖNCE çağrılır; bu yüzden
    // kanal aşağıdaki `handleIntent`ten önce hazırdır.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = ShareChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) shareChannel?.handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shareChannel?.handleIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareChannel?.dispose()
        shareChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
