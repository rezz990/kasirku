import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = new URL('../ui/', import.meta.url);
const types = new Map([['.html', 'text/html; charset=utf-8'], ['.js', 'text/javascript; charset=utf-8'], ['.css', 'text/css; charset=utf-8'], ['.svg', 'image/svg+xml']]);
const files = new Set(['index.html', 'app.js', 'pos.js', 'device.js', 'strings.js', 'styles.css', 'assets/kasirku.svg']);
const server = http.createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  const name = pathname === '/' ? 'index.html' : pathname.slice(1);
  if (request.method !== 'GET' || !files.has(name)) { response.writeHead(404).end(); return; }
  try {
    const data = await readFile(fileURLToPath(new URL(name, root)));
    response.writeHead(200, { 'Content-Type': types.get(name.slice(name.lastIndexOf('.'))), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    response.end(data);
  } catch { response.writeHead(500).end(); }
});
server.listen(4173, '127.0.0.1', () => console.log('KasirKu UI preview: http://127.0.0.1:4173 (no database connection)'));
