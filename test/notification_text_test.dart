import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/notification_service.dart';
import 'package:kaydet/domain/use_cases/notification_text.dart';

void main() {
  group('MailNotificationText', () {
    test('başlık gönderen adı, kapalı metin konu', () {
      final text = MailNotificationText.from(
        fromName: 'GitHub',
        fromEmail: 'noreply@github.com',
        subject: '[GitHub] coderabbitai is requesting updated permissions',
        preview: 'Updated Permissions Request The GitHub App coderabbitai',
      );

      expect(text.sender, 'GitHub');
      expect(
        text.subject,
        '[GitHub] coderabbitai is requesting updated permissions',
      );
      expect(
        text.expandedBody,
        '[GitHub] coderabbitai is requesting updated permissions\n'
        'Updated Permissions Request The GitHub App coderabbitai',
      );
    });

    test('ad yoksa e-posta, ikisi de yoksa yer tutucu gösterilir', () {
      expect(
        MailNotificationText.from(
          fromName: '  ',
          fromEmail: 'a@b.com',
          subject: 's',
          preview: '',
        ).sender,
        'a@b.com',
      );
      expect(
        MailNotificationText.from(
          fromName: '',
          fromEmail: '',
          subject: 's',
          preview: '',
        ).sender,
        '(gönderen yok)',
      );
    });

    test('boş konu yer tutucuyla değişir', () {
      final text = MailNotificationText.from(
        fromName: 'Ali',
        fromEmail: 'ali@x.com',
        subject: '   ',
        preview: '',
      );
      expect(text.subject, '(konu yok)');
    });

    test('konu ve önizlemedeki satır sonları/boşluklar tek boşluğa iner', () {
      final text = MailNotificationText.from(
        fromName: 'Ali',
        fromEmail: 'ali@x.com',
        subject: 'Toplantı\n  notları',
        preview: 'Merhaba\n\nekte   notlar var',
      );
      expect(text.subject, 'Toplantı notları');
      expect(text.preview, 'Merhaba ekte notlar var');
    });

    test('konuyla aynı önizleme tekrarlanmaz', () {
      final text = MailNotificationText.from(
        fromName: 'Ali',
        fromEmail: 'ali@x.com',
        subject: 'Merhaba',
        preview: 'Merhaba',
      );
      expect(text.preview, isEmpty);
      expect(text.expandedBody, 'Merhaba');
    });
  });

  group('NotificationService yük çözümleme', () {
    test('geçerli yükten ileti kimliğini okur', () {
      expect(NotificationService.parseMessageId('message:42'), 42);
    });

    test('bozuk ya da yabancı yükte null döner', () {
      expect(NotificationService.parseMessageId(null), isNull);
      expect(NotificationService.parseMessageId('other:42'), isNull);
      expect(NotificationService.parseMessageId('message:abc'), isNull);
    });
  });
}
