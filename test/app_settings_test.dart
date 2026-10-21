import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Gruplandırma tercihi varsayılan olarak kapalı ve kalıcıdır', () async {
    final store = await AppSettingsStore.create();

    expect(store.read().groupMessages, isFalse);

    await store.write(const AppSettings(groupMessages: true));

    expect(store.read().groupMessages, isTrue);
  });
}
