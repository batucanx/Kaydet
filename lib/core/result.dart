/// Sonuç ve hata tipleri.
///
/// Kural: Repository ve servis katmanları istisna fırlatmaz. Her işlem
/// [Result] döner. Böylece UI katmanı her hata durumunu derleme zamanında
/// ele almak zorunda kalır ve beklenmeyen çökme oluşmaz.
library;

/// Kullanıcıya gösterilebilir hata.
sealed class AppFailure {
  const AppFailure({this.detail});

  /// Teknik ayrıntı — yalnızca loglara ve hata ayıklama ekranına gider.
  final String? detail;

  /// Kullanıcıya gösterilecek Türkçe mesaj.
  String get userMessage;

  /// Kullanıcının bu hatayı kendisi düzeltebilir mi?
  bool get isActionable => false;

  @override
  String toString() => '$runtimeType(${detail ?? userMessage})';
}

/// Kullanıcı adı veya şifre hatalı.
final class AuthFailure extends AppFailure {
  const AuthFailure({super.detail});

  @override
  String get userMessage => 'Kullanıcı adı veya şifre hatalı.';

  @override
  bool get isActionable => true;
}

/// Sunucuya ulaşılamıyor (ağ yok, DNS, zaman aşımı).
final class ConnectionFailure extends AppFailure {
  const ConnectionFailure({super.detail});

  @override
  String get userMessage => 'Sunucuya ulaşılamıyor. Bağlantınızı kontrol edin.';
}

/// TLS/SSL el sıkışması başarısız.
final class TlsFailure extends AppFailure {
  const TlsFailure({super.detail});

  @override
  String get userMessage =>
      'Güvenli bağlantı kurulamadı. Port ve güvenlik ayarlarını kontrol edin.';

  @override
  bool get isActionable => true;
}

/// Klasör sunucuda bulunamadı.
final class MailboxNotFoundFailure extends AppFailure {
  const MailboxNotFoundFailure({super.detail, this.path});

  final String? path;

  @override
  String get userMessage => 'Klasör bulunamadı${path != null ? ': $path' : ''}.';
}

/// UIDVALIDITY değişti — yerel önbellek geçersiz.
///
/// Bu hata kullanıcıya gösterilmez; senkronizasyon katmanı yakalayıp
/// klasörü baştan indirir.
final class UidValidityChangedFailure extends AppFailure {
  const UidValidityChangedFailure({
    required this.mailboxPath,
    required this.oldValue,
    required this.newValue,
    super.detail,
  });

  final String mailboxPath;
  final int? oldValue;
  final int newValue;

  @override
  String get userMessage => 'Klasör yeniden eşitleniyor.';
}

/// Posta kutusu kotası doldu.
final class QuotaExceededFailure extends AppFailure {
  const QuotaExceededFailure({super.detail});

  @override
  String get userMessage => 'Posta kutusu dolu. Yer açmanız gerekiyor.';

  @override
  bool get isActionable => true;
}

/// Sunucu komutu reddetti.
final class ServerFailure extends AppFailure {
  const ServerFailure({super.detail, this.isPermanent = false});

  /// Kalıcı hata (5xx) ise tekrar denenmez.
  final bool isPermanent;

  @override
  String get userMessage => 'Sunucu isteği reddetti.';
}

/// MIME ayrıştırma başarısız — mail ham haliyle gösterilir.
final class ParseFailure extends AppFailure {
  const ParseFailure({super.detail});

  @override
  String get userMessage => 'İleti çözümlenemedi, ham haliyle gösteriliyor.';
}

/// Yerel depolama hatası.
final class StorageFailure extends AppFailure {
  const StorageFailure({super.detail});

  @override
  String get userMessage => 'Cihaz depolamasına yazılamadı.';
}

/// Alıcı sunucu tarafından reddedildi (kalıcı).
final class RecipientRejectedFailure extends AppFailure {
  const RecipientRejectedFailure({required this.recipients, super.detail});

  final List<String> recipients;

  @override
  String get userMessage =>
      'Alıcı reddedildi: ${recipients.join(', ')}. Adresi kontrol edin.';

  @override
  bool get isActionable => true;
}

/// Beklenmeyen hata — yakalanamayan her şey buraya düşer.
final class UnknownFailure extends AppFailure {
  const UnknownFailure({super.detail});

  @override
  String get userMessage => 'Beklenmeyen bir hata oluştu.';
}

/// Başarı veya hata taşıyan sonuç tipi.
sealed class Result<T> {
  const Result();

  /// Başarılı sonuç.
  const factory Result.ok(T value) = Ok<T>;

  /// Hatalı sonuç.
  const factory Result.err(AppFailure failure) = Err<T>;

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  /// Başarılıysa değeri, değilse `null`.
  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  /// Hatalıysa hatayı, değilse `null`.
  AppFailure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final failure) => failure,
      };

  /// Başarılıysa değeri, değilse [fallback].
  T orElse(T fallback) => valueOrNull ?? fallback;

  /// Değeri dönüştürür, hatayı olduğu gibi taşır.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// İki dala ayrılır.
  R fold<R>(
    R Function(T value) onOk,
    R Function(AppFailure failure) onErr,
  ) =>
      switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final failure) => onErr(failure),
      };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'Err($failure)';
}

/// Değer taşımayan başarı sonucu için kısayol.
typedef VoidResult = Result<void>;

/// `void` sonuç için sabit başarı.
const VoidResult okVoid = Ok<void>(null);
