// Локальный статический сервер для сайта РЕЗЕРВ (на Vercel не используется — там сайт раздаётся как статика).
// Запуск: npm start  →  http://localhost:3000
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 3000;
const ROOT = path.join(__dirname, 'site');
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function send(res, status, body, type) {
  res.writeHead(status, { 'Content-Type': type || 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache' });
  res.end(body);
}

http.createServer((req, res) => {
  let urlPath;
  try { urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname); }
  catch { return send(res, 400, 'Bad request'); }

  if (urlPath === '/') urlPath = '/index.html';
  else if (urlPath === '/cabinet') urlPath = '/cabinet.html';
  else if (urlPath === '/privacy') urlPath = '/privacy.html';
  const file = path.join(ROOT, urlPath);
  if (!file.startsWith(ROOT + path.sep)) return send(res, 403, 'Forbidden');

  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, 'Not found');
    send(res, 200, data, MIME[path.extname(file).toLowerCase()] || 'application/octet-stream');
  });
}).listen(PORT, () => {
  console.log(`РЕЗЕРВ: http://localhost:${PORT}  (кабинет: http://localhost:${PORT}/cabinet)`);
});
