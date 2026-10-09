// Mail render laboratuvarı için küçük statik sunucu (bağımlılık yok).
//   node tool/mail_render_lab/serve.mjs [port]
// /               → tool/mail_render_lab/runner.html
// /build/...      → depo kökündeki build/ (flutter test'in ürettiği belgeler)
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const port = Number(process.argv[2] ?? 4173);
const types = { '.html': 'text/html; charset=utf-8', '.json': 'application/json', '.js': 'text/javascript' };

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname === '/' ? '/tool/mail_render_lab/runner.html' : url.pathname;
  const file = normalize(join(root, path));
  const allowed = file.startsWith(join(root, 'build', 'mail_lab')) || file.startsWith(join(root, 'tool', 'mail_render_lab'));
  if (!allowed) { res.writeHead(403).end('forbidden'); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
}).listen(port, () => console.log(`mail lab: http://localhost:${port}/`));
