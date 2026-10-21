package tr.com.pazarlik.kaydet

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** `İndirilenler`e yazılmış tek bir dosya. */
data class SavedFile(val uri: Uri, val name: String, val mimeType: String)

/**
 * Ekler cihaza kaydedilince "İndirme tamamlandı" bildirimi gösterir (Outlook'un
 * toplu indirme bildirimi gibi).
 *
 * - **Tek dosya:** başlık dosya adı; dokununca dosya açılır.
 * - **Birden çok dosya:** TEK özet bildirim ("N ek kaydedildi"); dokununca
 *   `İndirilenler/Kaydet` klasörü açılır.
 *
 * Bildirim yalnızca bilgidir: bildirim izni (Android 13+) ya da kanal kapalıysa
 * hiçbir şey gösterilmez ve izin İSTENMEZ.
 */
object SavedFilesNotifier {
    private const val CHANNEL_ID = "kaydet_downloads"
    private const val CHANNEL_NAME = "Kaydedilen ekler"
    private const val EXTERNAL_STORAGE_DOCUMENTS = "com.android.externalstorage.documents"
    private const val DIRECTORY_MIME = "vnd.android.document/directory"

    fun show(context: Context, files: List<SavedFile>, relativePath: String) {
        if (files.isEmpty()) return
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        ensureChannel(context)

        val single = files.singleOrNull()
        val title = single?.name?.ifEmpty { null } ?: "${files.size} ek kaydedildi"
        val text = if (single != null) "İndirme tamamlandı" else relativePath.replace("Download/", "İndirilenler/")
        val tapIntent = if (single != null) {
            openFileIntent(context, single) ?: openFolderIntent(context, relativePath)
        } else {
            openFolderIntent(context, relativePath)
        }

        val requestCode = (System.currentTimeMillis() and 0x7FFFFFFF).toInt()
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_kaydet)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
        if (tapIntent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    requestCode,
                    tapIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        try {
            manager.notify(requestCode, builder.build())
        } catch (_: SecurityException) {
            // İzin tam bu sırada geri alındı; bildirim zaten isteğe bağlı.
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Sessiz: ses/titreşim ve ekranda belirme yok, yalnızca çekmecede durur.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW),
        )
    }

    /** Dosyayı açabilecek bir uygulama yoksa `null` (çağıran klasöre düşer). */
    private fun openFileIntent(context: Context, file: SavedFile): Intent? {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(file.uri, file.mimeType.ifEmpty { "*/*" })
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return intent.takeIf { it.resolveActivity(context.packageManager) != null }
    }

    /**
     * Klasörü belirli bir yerde açmanın garantili bir API'si yok: önce sistem
     * belge seçicisinin klasör URI'si denenir (Google Dosyalar'da çalışır),
     * olmazsa sistemin İndirilenler ekranı açılır.
     */
    private fun openFolderIntent(context: Context, relativePath: String): Intent? {
        val documentId = Uri.encode("primary:$relativePath")
        val folder = Intent(Intent.ACTION_VIEW)
            .setDataAndType(
                Uri.parse("content://$EXTERNAL_STORAGE_DOCUMENTS/document/$documentId"),
                DIRECTORY_MIME,
            )
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (folder.resolveActivity(context.packageManager) != null) return folder

        val downloads = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return downloads.takeIf { it.resolveActivity(context.packageManager) != null }
    }
}
