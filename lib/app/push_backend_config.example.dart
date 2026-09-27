/// Push backend bağlantı bilgileri için şablon. Bu dosyayı
/// `push_backend_config.dart` olarak kopyalayıp doldurun — o dosya
/// `.gitignore`'dadır ve ASLA depoya eklenmemelidir (bkz. backend/README.md
/// "Uygulamaya bağlama").
///
/// Eskiden bu değerler `--dart-define=PUSH_BACKEND_URL=...` ile derleme
/// zamanında veriliyordu; Xcode'un "Run" düğmesi önceki bir `flutter run`
/// çağrısının dart-define'larını hatırlamadığından bu, özelliğin sessizce
/// kapalı kaldığı bir build'i fark etmeden test etmeyi çok kolaylaştırıyordu.
/// Düz, depoya eklenmeyen bir Dart sabiti her build'e (Xcode Run,
/// `flutter run`, `flutter build ipa`) ekstra bir bayrak gerekmeden girer.
class PushBackendSecrets {
  const PushBackendSecrets._();

  /// Backend'in https adresi (ör. `https://push.kaydet.example.com`). Boş
  /// bırakılırsa iOS anlık bildirim özelliği tümüyle kapalı kalır — diğer
  /// hiçbir davranış etkilenmez.
  static const String baseUrl = '';

  /// `backend/.env` dosyasındaki `API_KEY` ile birebir aynı olmalı. APNs
  /// özel anahtarı (.p8) DEĞİLDİR — o hiçbir zaman backend dışına çıkmaz.
  static const String apiKey = '';
}
