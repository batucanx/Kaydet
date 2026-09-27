import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';

/// Gönderim sonucu.
///
/// [mimeSource] gönderilen iletinin ham hâlidir (Bcc alıcıları dahil: kendi
/// kopyamızda görünmeleri gerekir); Gönderilenler klasörüne `APPEND` etmek
/// için gerekir. SMTP gönderimi ile APPEND ayrı iki adımdır:
/// tek işlem sayılırsa APPEND hatasında gönderim tekrarlanır ve alıcı
/// iletiyi iki kez alır.
class SentMessage {
  const SentMessage({required this.messageId, required this.mimeSource});
  final String messageId;
  final String mimeSource;
}

abstract class SmtpService {
  /// İletiyi gönderir.
  Future<Result<SentMessage>> send({
    required MailServerConfig config,
    required OutgoingMessage message,
  });

  /// Ayarların doğruluğunu sınar (giriş ekranı için).
  Future<Result<void>> verify(MailServerConfig config);
}

class EnoughMailSmtpService implements SmtpService {
  EnoughMailSmtpService();

  @override
  Future<Result<SentMessage>> send({
    required MailServerConfig config,
    required OutgoingMessage message,
  }) async {
    // Dosya okuma, base64 ve MIME oluşturma ağırdır (25 MB'lık bir ek yüzlerce
    // MB'lık geçici metne dönüşür); arayüz isolate'inde çalışsaydı ekran
    // donar, düşük belleği olan cihazda uygulama çökerdi.
    final built = await MimeBuilder.buildForWire(message);
    if (built is Err<WireMessage>) return Err(built.failure);
    final wire = (built as Ok<WireMessage>).value;

    em.SmtpClient? client;
    try {
      client = await _connect(config);

      // Bcc alıcıları YALNIZCA zarfta (`RCPT TO`) gider. İleti başlıklarına
      // hiç yazılmaz: `enough_mail` gönderirken `^Bcc:.*` satırını siler ama
      // uzun bir Bcc listesi 76 karakterde katlanır ve devam satırları
      // silinmeden kalıp bir önceki başlığa (To/Cc) yapışırdı — yani gizli
      // alıcılar diğer alıcılara görünürdü.
      final response = await client.sendMessageText(
        wire.source,
        em.MailAddress(message.from.name, message.from.email),
        message.allRecipients
            .map((a) => em.MailAddress(a.name, a.email))
            .toList(),
        use8BitEncoding: false,
      );

      if (!response.isOkStatus) {
        return Err(_mapSmtpResponse(response, message));
      }

      return Ok(
        SentMessage(
          messageId: wire.messageId,
          mimeSource: MimeBuilder.withBccHeader(wire.source, message.bcc),
        ),
      );
    } catch (error) {
      return Err(_mapError(error));
    } finally {
      await _close(client);
    }
  }

  @override
  Future<Result<void>> verify(MailServerConfig config) async {
    em.SmtpClient? client;
    try {
      client = await _connect(config);
      return okVoid;
    } catch (error) {
      return Err(_mapError(error));
    } finally {
      await _close(client);
    }
  }

  Future<em.SmtpClient> _connect(MailServerConfig config) async {
    // İstemci alan adı: sunucular EHLO'da geçerli bir ad bekler.
    final domain = config.username.contains('@')
        ? config.username.split('@').last
        : 'kaydet.local';
    final client = em.SmtpClient(domain, isLogEnabled: false);

    await client.connectToServer(
      config.host,
      config.port,
      isSecure: config.isImplicitTls,
      timeout: const Duration(seconds: 25),
    );
    await client.ehlo();

    if (config.security == SocketSecurity.startTls) {
      final tls = await client.startTls();
      if (!tls.isOkStatus) {
        throw const _SmtpFailure('STARTTLS reddedildi', isTls: true);
      }
    }

    final (secret, mechanism) = switch (config.credential) {
      PasswordCredential(:final password) => (
          password,
          client.serverInfo.supportsAuth(em.AuthMechanism.plain)
              ? em.AuthMechanism.plain
              : em.AuthMechanism.login,
        ),
    };

    final auth = await client.authenticate(
      config.username,
      secret,
      mechanism,
    );
    if (!auth.isOkStatus) {
      throw const _SmtpFailure('Kimlik doğrulama reddedildi', isAuth: true);
    }
    return client;
  }

  Future<void> _close(em.SmtpClient? client) async {
    if (client == null) return;
    try {
      await client.quit();
    } catch (_) {
      // Sunucu kapanışı reddetse de soketi bırak.
    }
    try {
      await client.disconnect();
    } catch (_) {}
  }

  AppFailure _mapSmtpResponse(em.SmtpResponse response, OutgoingMessage msg) {
    final code = response.code ?? 0;
    final text = response.responseLines.map((l) => l.message).join(' ');

    // 5xx kalıcı hatadır — tekrar denenmez.
    if (code >= 500 && code < 600) {
      if (code == 550 || code == 551 || code == 553 || code == 554) {
        return RecipientRejectedFailure(
          recipients: msg.allRecipients.map((a) => a.email).toList(),
          detail: '$code $text',
        );
      }
      if (code == 552) {
        return QuotaExceededFailure(detail: '$code $text');
      }
      return ServerFailure(detail: '$code $text', isPermanent: true);
    }
    // 4xx geçicidir — kuyrukta tekrar denenir.
    return ServerFailure(detail: '$code $text');
  }

  AppFailure _mapError(Object error) {
    if (error is _SmtpFailure) {
      if (error.isAuth) return AuthFailure(detail: error.message);
      if (error.isTls) return TlsFailure(detail: error.message);
      return ServerFailure(detail: error.message);
    }
    if (error is SocketException) {
      return ConnectionFailure(detail: error.message);
    }
    if (error is HandshakeException) return TlsFailure(detail: error.message);
    if (error is TlsException) return TlsFailure(detail: error.message);
    if (error is TimeoutException) {
      return const ConnectionFailure(detail: 'zaman aşımı');
    }
    if (error is em.SmtpException) {
      final text = error.response.responseLines
          .map((l) => '${l.code} ${l.message}')
          .join(' ');
      final upper = text.toUpperCase();
      if (upper.contains('AUTH') || (error.response.code ?? 0) == 535) {
        return AuthFailure(detail: text);
      }
      return ServerFailure(
        detail: text,
        isPermanent: (error.response.code ?? 0) >= 500,
      );
    }
    if (error is em.MailException) {
      return ServerFailure(detail: error.message ?? '$error');
    }
    return UnknownFailure(detail: '$error');
  }
}

class _SmtpFailure implements Exception {
  const _SmtpFailure(this.message, {this.isAuth = false, this.isTls = false});
  final String message;
  final bool isAuth;
  final bool isTls;
}

/// SMTP'ye giden ham ileti: Bcc başlığı İÇERMEZ (bkz.
/// `EnoughMailSmtpService.send`).
class WireMessage {
  const WireMessage({required this.source, required this.messageId});

  final String source;
  final String messageId;
}

/// Oluşturulmuş MIME iletisi.
class BuiltMessage {
  const BuiltMessage({
    required this.mime,
    required this.source,
    required this.messageId,
  });

  final em.MimeMessage mime;
  final String source;
  final String messageId;
}

/// [OutgoingMessage] → MIME dönüşümü.
///
/// Yanıtlarda `In-Reply-To` ve `References` başlıkları yazılır; bunlar
/// olmadan alıcının istemcisi yanıtı konuşmaya bağlayamaz.
abstract final class MimeBuilder {
  /// [message]'ı SMTP'ye gidecek ham metne çevirir — Bcc başlığı OLMADAN —
  /// ve bunu ayrı bir isolate'te yapar. Sonuç yalnızca metin taşır (isolate
  /// sınırından güvenle geçer).
  static Future<Result<WireMessage>> buildForWire(OutgoingMessage message) =>
      buildSourceInIsolate(message, includeBcc: false);

  /// [build]'in ayrı bir isolate'te çalışan hâli: dosya okuma ve base64 ana
  /// isolate'i (dolayısıyla ekranı) bloke etmez. Sonuç yalnızca metin taşır.
  static Future<Result<WireMessage>> buildSourceInIsolate(
    OutgoingMessage message, {
    bool includeBcc = true,
    bool skipMissingAttachments = false,
  }) => Isolate.run(
    () => _buildWireMessage(
      message,
      includeBcc: includeBcc,
      skipMissingAttachments: skipMissingAttachments,
    ),
  );

  /// Gönderilen iletinin KENDİ kopyası (Gönderilenler) için, Bcc alıcılarını
  /// başlık olarak ham metnin başına ekler.
  static String withBccHeader(String source, List<EmailAddress> bcc) {
    if (bcc.isEmpty) return source;
    final buffer = StringBuffer();
    em.Header(
      'Bcc',
      bcc.map((a) => em.MailAddress(a.name, a.email).encode()).join(', '),
    ).render(buffer);
    buffer.write(source);
    return buffer.toString();
  }

  /// [message]'dan MIME oluşturur.
  ///
  /// [includeBcc] `false` ise Bcc başlığı yazılmaz (SMTP gönderimi).
  /// [skipMissingAttachments] `false` iken (varsayılan) cihazda artık olmayan
  /// bir ek [AttachmentMissingFailure] ile reddedilir: ek olmadan göndermek
  /// alıcıya, kullanıcının eklediğini sandığı dosya olmadan bir ileti
  /// ulaştırır. Taslak/Gönderilenler kopyası gibi yedek kopyalarda `true`
  /// verilir — orada eksik bir ek yüzünden kopyanın hiç yazılmaması daha
  /// kötüdür.
  static Result<BuiltMessage> build(
    OutgoingMessage message, {
    bool includeBcc = true,
    bool skipMissingAttachments = false,
  }) {
    try {
      final attachmentFiles = <File>[];
      final missing = <String>[];
      for (final path in message.attachmentPaths) {
        final file = File(path);
        if (file.existsSync()) {
          attachmentFiles.add(file);
        } else {
          missing.add(path.split(RegExp(r'[\\/]')).last);
        }
      }
      if (missing.isNotEmpty && !skipMissingAttachments) {
        return Err(
          AttachmentMissingFailure(
            fileNames: missing,
            detail: 'ek dosyası yok: ${missing.join(', ')}',
          ),
        );
      }

      final builder = em.MessageBuilder()
        ..from = [em.MailAddress(message.from.name, message.from.email)]
        ..to = message.to
            .map((a) => em.MailAddress(a.name, a.email))
            .toList()
        ..subject = message.subject
        ..date = DateTime.now();

      if (message.cc.isNotEmpty) {
        builder.cc =
            message.cc.map((a) => em.MailAddress(a.name, a.email)).toList();
      }
      if (includeBcc && message.bcc.isNotEmpty) {
        builder.bcc =
            message.bcc.map((a) => em.MailAddress(a.name, a.email)).toList();
      }

      final messageId = message.messageId ??
          em.MessageBuilder.createMessageId(
            _domainOf(message.from.email),
            isChat: false,
          );
      builder.messageId = messageId;

      if (message.inReplyTo != null && message.inReplyTo!.isNotEmpty) {
        builder.setHeader('In-Reply-To', _bracket(message.inReplyTo!));
      }
      if (message.references != null && message.references!.isNotEmpty) {
        builder.setHeader('References', message.references!);
      }
      builder.setHeader('X-Mailer', 'KAYDET');

      final hasHtml = message.html != null && message.html!.trim().isNotEmpty;
      final hasAttachments = attachmentFiles.isNotEmpty;

      // Düz metin + HTML ASLA kardeş (`multipart/mixed`) parçalar olarak
      // gönderilmez: istemciler karışık parçaları art arda gösterir, yani
      // alıcı önce düz metni sonra biçimli HTML'i (ya da tersini) görür ve
      // hangisinin çizileceği istemciye göre değişir. Doğru yapı
      // `multipart/alternative`dir: alıcının istemcisi biri seçer, HTML
      // gösterebilen istemci biçimli olanı çizer (RFC 2046 §5.1.4 — en sadık
      // biçim, yani HTML, SONA konur).
      //
      // Ekler varsa kök `multipart/mixed` olur ve alternatif çifti onun İLK
      // çocuğu, ekler ise kardeşleridir.
      if (hasAttachments) {
        builder.setContentType(
          em.MediaType.fromSubtype(em.MediaSubtype.multipartMixed),
        );
        if (hasHtml) {
          builder.addMultipartAlternative(
            plainText: message.plainText,
            htmlText: message.html!,
          );
        } else {
          builder.addTextPlain(message.plainText);
        }
      } else if (hasHtml) {
        builder.setContentType(
          em.MediaType.fromSubtype(em.MediaSubtype.multipartAlternative),
        );
        builder.addTextPlain(message.plainText);
        builder.addTextHtml(message.html!);
      } else {
        builder.addTextPlain(message.plainText);
      }

      for (final file in attachmentFiles) {
        final bytes = file.readAsBytesSync();
        final name = file.path.split(RegExp(r'[\\/]')).last;
        builder.addBinary(
          bytes,
          em.MediaType.guessFromFileName(name),
          filename: name,
        );
      }

      final mime = builder.buildMimeMessage();
      return Ok(
        BuiltMessage(
          mime: mime,
          source: mime.renderMessage(),
          messageId: _unbracket(messageId),
        ),
      );
    } catch (error) {
      return Err(UnknownFailure(detail: 'MIME oluşturulamadı: $error'));
    }
  }

  static String _domainOf(String email) {
    final at = email.indexOf('@');
    if (at < 0 || at == email.length - 1) return 'kaydet.local';
    return email.substring(at + 1);
  }

  static String _bracket(String id) =>
      id.startsWith('<') ? id : '<${_unbracket(id)}>';

  static String _unbracket(String id) {
    var value = id.trim();
    if (value.startsWith('<')) value = value.substring(1);
    if (value.endsWith('>')) value = value.substring(0, value.length - 1);
    return value;
  }
}

/// [MimeBuilder.buildSourceInIsolate]'in isolate giriş noktası (üst düzey
/// işlev: yalnızca verilen değerleri yakalar).
Result<WireMessage> _buildWireMessage(
  OutgoingMessage message, {
  required bool includeBcc,
  required bool skipMissingAttachments,
}) => MimeBuilder.build(
  message,
  includeBcc: includeBcc,
  skipMissingAttachments: skipMissingAttachments,
).map(
  (built) => WireMessage(source: built.source, messageId: built.messageId),
);
