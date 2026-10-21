/// Sunucudan gelen iade (bounce) iletisinin sonucu.
class BounceReport {
  const BounceReport({required this.reason});

  /// Kullanıcıya gösterilecek neden (Türkçe özet + varsa sunucunun kendi metni).
  final String reason;
}

/// Posta sunucusunun gönderdiği iade iletilerini (RFC 3464 teslim durumu
/// bildirimleri ve düz metin iadeler) tanır ve nedenini çıkarır.
///
/// SMTP kabulü (`250`) teslim garantisi değildir: alıcı sunucusu iletiyi
/// reddederse hata yalnızca sonradan gelen bir iade iletisiyle öğrenilir.
abstract final class BounceParser {
  static final _senderPattern = RegExp(
    r'mailer-daemon|postmaster|mail delivery (sub)?system|mail delivery service',
    caseSensitive: false,
  );
  static final _subjectPattern = RegExp(
    r'undeliver|delivery status notification|returned mail|failure notice|'
    r'delivery failure|mail delivery failed|could not be delivered|'
    r'teslim edilemedi|iletilemedi|ulaştırılamadı',
    caseSensitive: false,
  );

  /// Gelen kutusundaki iletinin iade iletisi OLABİLECEĞİNİ söyler. Yalnızca
  /// aday seçer (kaynağı indirilir); iletinin hangi gönderime ait olduğu
  /// [mentionsMessageId] ile kesinleşir.
  static bool looksLikeBounce({
    required String fromEmail,
    String fromName = '',
    required String subject,
  }) =>
      _senderPattern.hasMatch('$fromName $fromEmail') ||
      _subjectPattern.hasMatch(subject);

  /// İade iletisinin ham kaynağı, gönderilen iletinin `Message-ID` değerini
  /// içeriyor mu? İade iletileri orijinal başlıkları (veya iletinin kendisini)
  /// taşır. `<>` parantezli ve parantezsiz biçimler eşdeğerdir.
  static bool mentionsMessageId(String source, String messageId) {
    final bare = messageId.trim().replaceAll(RegExp(r'^<|>$'), '');
    if (bare.isEmpty) return false;
    return source.toLowerCase().contains(bare.toLowerCase());
  }

  /// İade iletisinin ham kaynağını çözer. Teslim hatası DEĞİLSE (gecikme,
  /// teslim edildi bildirimi) `null` döner.
  static BounceReport? parse(String source) {
    // Katlanmış başlık satırlarını birleştir.
    final text = source.replaceAll(RegExp(r'\r?\n[ \t]+'), ' ');

    String? field(String name) => RegExp(
      '^$name:[ \\t]*(.+?)\\r?\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text)?.group(1)?.trim();

    final action = field('Action')?.toLowerCase();
    if (action != null && action != 'failed') return null;

    final status = RegExp(
      r'^Status:[ \t]*([245]\.\d{1,3}\.\d{1,3})',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text)?.group(1);

    var diagnostic = field('Diagnostic-Code');
    if (diagnostic != null) {
      diagnostic = diagnostic
          .replaceFirst(RegExp(r'^[A-Za-z0-9-]+;\s*'), '')
          .trim();
      if (diagnostic.length > 200) diagnostic = diagnostic.substring(0, 200);
      if (diagnostic.isEmpty) diagnostic = null;
    }

    var recipient = field('Final-Recipient')?.replaceFirst(
      RegExp(r'^rfc822;\s*', caseSensitive: false),
      '',
    );
    if (recipient != null && recipient.isEmpty) recipient = null;

    // Geçici (4.x.x) durum ve açık bir "failed" yoksa gecikme bildirimidir.
    if (action == null && status != null && status.startsWith('4')) {
      return null;
    }

    final summary = _summaryFor(status);
    final parts = [
      if (recipient != null) '$recipient:',
      summary,
      if (diagnostic != null) '— $diagnostic',
    ];
    return BounceReport(reason: parts.join(' '));
  }

  static String _summaryFor(String? status) {
    if (status == null) return 'İleti alıcıya teslim edilemedi';
    final p = status.split('.');
    final klass = p[0];
    final subject = p.length > 1 ? p[1] : '';
    final detail = p.length > 2 ? p[2] : '';
    if (klass == '4') return 'Geçici sorun, sunucu yeniden deniyor';
    return switch (subject) {
      '1' => switch (detail) {
        '1' || '2' || '10' => 'Alıcı adresi bulunamadı',
        _ => 'Alıcı adresi geçersiz',
      },
      '2' => switch (detail) {
        '1' => 'Alıcının posta kutusu devre dışı',
        '2' => 'Alıcının posta kutusu dolu',
        '3' => 'İleti alıcının kabul ettiği boyuttan büyük',
        _ => 'Alıcının posta kutusu iletiyi kabul etmedi',
      },
      '3' when detail == '4' => 'İleti alıcının kabul ettiği boyuttan büyük',
      '4' => 'Alıcının sunucusuna ulaşılamadı',
      '7' => 'Alıcı sunucusu iletiyi reddetti (spam veya güvenlik politikası)',
      _ => 'İleti alıcıya teslim edilemedi',
    };
  }
}
