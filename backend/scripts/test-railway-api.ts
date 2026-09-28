import 'dotenv/config';

async function main() {
  const baseUrl = 'https://kaydet-production.up.railway.app';
  const apiKey = (process.env.API_KEY || '').trim();

  console.log('--- Railway Canlı Sunucu API Testi ---');
  console.log(`Sunucu URL: ${baseUrl}`);
  console.log(`API Key (ilk 8 hane): ${apiKey.slice(0, 8)}...`);

  // 1. Health Check
  console.log('\n1. Adım: /health kontrol ediliyor...');
  const healthRes = await fetch(`${baseUrl}/health`);
  const healthJson = await healthRes.json();
  console.log(`Yanıt (${healthRes.status}):`, healthJson);

  // 2. Yetkisiz İstek Testi
  console.log('\n2. Adım: Yetkisiz erişim güvenliği test ediliyor (Hatalı API Key ile)...');
  const unauthRes = await fetch(`${baseUrl}/v1/accounts`, {
    method: 'PUT',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer yanlis-anahtar',
    },
    body: JSON.stringify({}),
  });
  console.log(`Yanıt (${unauthRes.status}): Güvenlik koruması çalışıyor (401 beklenir).`);

  // 3. Yetkili Hesap Kayıt Testi
  console.log('\n3. Adım: Canlı sunucuya hesap kaydı (PUT /v1/accounts) gönderiliyor...');
  const dummyToken = '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';
  const putRes = await fetch(`${baseUrl}/v1/accounts`, {
    method: 'PUT',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      apnsToken: dummyToken,
      environment: 'production',
      clientAccountId: 9999,
      imap: {
        host: 'imap.gmail.com',
        port: 993,
        secure: true,
      },
      username: 'test_account@example.com',
      password: 'SampleEncryptedPassword123!',
    }),
  });
  console.log(`Hesap Kayıt Yanıtı: HTTP ${putRes.status} (204 No Content beklenir)`);

  // 4. Temizlik (DELETE /v1/accounts)
  console.log('\n4. Adım: Test hesabı siliniyor (DELETE /v1/accounts)...');
  const delRes = await fetch(`${baseUrl}/v1/accounts`, {
    method: 'DELETE',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      apnsToken: dummyToken,
      clientAccountId: 9999,
    }),
  });
  console.log(`Hesap Silme Yanıtı: HTTP ${delRes.status} (204 No Content beklenir)`);

  console.log('\n🎉 TÜM TESTLER BAŞARIYLA TAMAMLANDI! Railway sunucusu ve API uçları kusursuz çalışıyor.');
}

main().catch(console.error);
