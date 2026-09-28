import 'dotenv/config';
import { readFileSync } from 'node:fs';
import { ApnsClient } from '../src/apns.js';

async function main() {
  const keepAlive = setInterval(() => {}, 1000);
  console.log('--- Apple APNs Bağlantı ve Yetkilendirme Testi Başlatılıyor ---');
  
  const keyPath = process.env.APNS_KEY_PATH?.replace(/^"|"$/g, '') || '';
  const keyId = process.env.APNS_KEY_ID || '';
  const teamId = process.env.APNS_TEAM_ID || '';
  const topic = process.env.APNS_BUNDLE_ID || '';

  console.log(`Key ID: ${keyId}`);
  console.log(`Team ID: ${teamId}`);
  console.log(`Bundle ID (Topic): ${topic}`);
  console.log(`Key Dosyası: ${keyPath}`);

  let keyPem: string;
  try {
    keyPem = readFileSync(keyPath, 'utf8');
    console.log('✅ .p8 dosyası başarıyla okundu.');
  } catch (e) {
    console.error('❌ .p8 dosyası okunamadı:', (e as Error).message);
    process.exit(1);
  }

  const client = new ApnsClient({
    keyPem,
    keyId,
    teamId,
    topic,
  });

  console.log('\n1. Adım: JWT İmzalama doğrulanıyor...');
  try {
    await client.verifyKey();
    console.log('✅ ES256 JWT Token başarıyla üretildi ve imzalandı!');
  } catch (e) {
    console.error('❌ JWT imzalama başarısız:', (e as Error).message);
    process.exit(1);
  }

  // 64-karakterlik sahte bir APNs cihaz token'ı
  const dummyDeviceToken = '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';

  console.log('\n2. Adım: Apple APNs Sunucularına (Sandbox) istek gönderiliyor...');
  console.log('Hedef: https://api.sandbox.push.apple.com');
  const resultSandbox = await client.send(dummyDeviceToken, 'development', {
    aps: {
      alert: { title: 'Test', body: 'Kaydet Test Bildirimi' },
      sound: 'default',
    },
  });

  console.log('Apple Sandbox Yanıtı:', JSON.stringify(resultSandbox));

  console.log('\n3. Adım: Apple APNs Sunucularına (Production) istek gönderiliyor...');
  console.log('Hedef: https://api.push.apple.com');
  const resultProd = await client.send(dummyDeviceToken, 'production', {
    aps: {
      alert: { title: 'Test', body: 'Kaydet Test Bildirimi' },
      sound: 'default',
    },
  });

  console.log('Apple Production Yanıtı:', JSON.stringify(resultProd));

  console.log('\n--- SONUÇ DEĞERLENDİRMESİ ---');
  if (resultSandbox.status === 'invalid_token' && resultSandbox.reason === 'BadDeviceToken') {
    console.log('🎉 HARİKA! Apple, kimlik bilgilerini (Key ID, Team ID, .p8 Anahtarı) DOĞRULADI!');
    console.log('Alınan "BadDeviceToken" yanıtı, Apple\'ın sunucumuzla tam yetkiyle el sıkıştığını kanıtlar.');
  } else if (resultSandbox.status === 'error' && resultSandbox.reason === 'InvalidProviderToken') {
    console.log('❌ HATA: Apple anahtarı veya Team ID/Key ID geçersiz.');
  } else if (resultSandbox.status === 'error' && resultSandbox.reason === 'TopicDisallowed') {
    console.log('⚠️ UYARI: Bundle ID (Topic) için Push Notification yetkisi developer.apple.com üzerinde açık değil.');
  } else {
    console.log('Durum:', resultSandbox);
  }

  client.close();
  clearInterval(keepAlive);
}

main().catch(console.error);
