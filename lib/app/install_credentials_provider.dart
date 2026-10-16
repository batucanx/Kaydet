import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/install_credentials.dart';
import '../data/services/secure_store.dart';

/// Sunucuya her istekte eşlik eden kurulum kimliği (bkz.
/// `install_credentials.dart`). Şifrelerle aynı güvenli depo ayarını kullanır.
final installCredentialsProvider = Provider<InstallCredentialsSource>(
  (ref) => SecureInstallCredentials(kaydetSecureStorage),
);
