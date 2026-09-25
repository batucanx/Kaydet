import 'package:flutter/material.dart';

import '../../../domain/models/mail_models.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Yazma ekranında bir alıcı alanı (Kime/Bilgi/Gizli) odaktayken altında açılan
/// "Hızlı Kişiler" şeridi — arama ekranındakiyle aynı görünüm (bkz.
/// [QuickContactAvatar]), ama dokununca arama yapmak yerine kişiyi alıcı
/// olarak ekler.
///
/// Şerit yalnızca sunar: hangi kişilerin gösterileceğine (zaten eklenmiş olanlar
/// çıkarılmış, en son kullanılana göre sıralı) ve seçilen kişinin nereye,
/// nasıl ekleneceğine çağıran karar verir.
class QuickContactsStrip extends StatelessWidget {
  const QuickContactsStrip({
    super.key,
    required this.contacts,
    required this.onSelected,
  });

  final List<EmailAddress> contacts;
  final ValueChanged<EmailAddress> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Şerit, odaktaki alıcı alanının parçası sayılır: `TextField`, kendi
    // dışındaki bir işaretçi basışında (fare/stylus; dokunma bunu yapmaz)
    // odağı bırakır ve odakla birlikte şerit de kaybolurdu — dokunma
    // tamamlanmadan.
    return TextFieldTapRegion(
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader('HIZLI KİŞİLER'),
            // Yazma ekranının gövdesi `keyboardDismissBehavior: onDrag` ile
            // kaydırılır ve bu dinleyici bildirimin eksenine/derinliğine
            // bakmaz: şeridi YATAY kaydırmak bile odağı (dolayısıyla klavyeyi
            // ve şeridin kendisini) kapatırdı. Bildirimi burada durdurmak,
            // şerit kaydırılırken alıcı alanının odakta kalmasını sağlar.
            NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final contact in contacts)
                      Padding(
                        padding: const EdgeInsets.only(right: Space.sm),
                        child: QuickContactAvatar(
                          // Adres anahtar: aynı kişi şeritte tekrar çıkmaz ve
                          // biri eklenip şeritten düşünce kalanlar yerinde
                          // kalır.
                          key: ValueKey(contact.email.toLowerCase()),
                          name: contact.name ?? '',
                          email: contact.email,
                          onTap: () => onSelected(contact),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
  }
}
