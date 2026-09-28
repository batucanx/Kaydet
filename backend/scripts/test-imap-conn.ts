import 'dotenv/config';
import { ImapFlow } from 'imapflow';

async function main() {
  console.log('--- IMAP Bağlantı ve Giriş Testi Başlatılıyor ---');
  const host = process.env.SMOKE_IMAP_HOST || 'imap.gmail.com';
  const port = Number(process.env.SMOKE_IMAP_PORT || 993);
  const user = process.env.SMOKE_IMAP_USER || '';
  const pass = process.env.SMOKE_IMAP_PASS || '';

  console.log(`Sunucu: ${host}:${port}`);
  console.log(`Kullanıcı: ${user}`);

  const client = new ImapFlow({
    host,
    port,
    secure: true,
    auth: {
      user,
      pass,
    },
    logger: false,
  });

  try {
    console.log('IMAP sunucusuna bağlanılıyor...');
    await client.connect();
    console.log('✅ IMAP bağlantısı ve kimlik doğrulama BAŞARILI!');

    console.log('INBOX (Gelen Kutusu) açılıyor...');
    const lock = await client.getMailboxLock('INBOX');
    try {
      console.log(`✅ INBOX başarıyla kilitlendi/açıldı. Toplam ileti: ${client.mailbox ? client.mailbox.exists : 'Bilinmiyor'}`);
    } finally {
      lock.release();
    }

    console.log('IDLE dinleyicisi destekleniyor mu kontrol ediliyor...');
    if (client.usableCapabilities.has('IDLE')) {
      console.log('✅ Sunucu IDLE (anlık bildirim dinleme) protokolünü destekliyor!');
    } else {
      console.log('⚠️ Sunucu IDLE desteklemiyor, yoklama (polling) gerekecek.');
    }

    await client.logout();
    console.log('✅ Çıkış yapıldı. IMAP katmanı %100 sağlıklı.');
  } catch (e) {
    console.error('❌ IMAP Test Hatası:', (e as Error).message);
  }
}

main().catch(console.error);
