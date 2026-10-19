// Chart-only: the avatars at /img/ of fxa.profileUrl, compose's "/img/ -> fxa-profile-static:1112"
// of your reverse proxy (FXA.md), the prefix stripped. An Ingress cannot strip a prefix
// portably, so the profile pod runs this next to the static server: GET and HEAD of
// /img/<path> on port 1114 are 127.0.0.1:1112's /<path>, any other path is 404 (another
// method 405). The avatar URLs kept in fxa_profile (IMG_URL, <profileUrl>/img/a/<id>) stay
// compose's.
'use strict';
const http = require('http');

const PORT = 1114;
const UPSTREAM = { host: '127.0.0.1', port: 1112 };
const PREFIX = '/img/';
// the hop-by-hop headers (RFC 9110, 7.6.1) are this connection's, not the upstream's
const HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade']);

function headers(from) {
  const out = {};
  for (const [name, value] of Object.entries(from)) {
    if (!HOP.has(name)) out[name] = value;
  }
  return out;
}

const server = http.createServer((req, res) => {
  if (!req.url.startsWith(PREFIX)) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('Not Found\n');
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { allow: 'GET, HEAD', 'content-type': 'text/plain' });
    res.end('Method Not Allowed\n');
    return;
  }
  const upstream = http.request(
    { ...UPSTREAM, method: req.method, path: req.url.slice(PREFIX.length - 1), headers: { ...headers(req.headers), host: `${UPSTREAM.host}:${UPSTREAM.port}` } },
    (up) => {
      res.writeHead(up.statusCode, headers(up.headers));
      up.pipe(res);
    }
  );
  upstream.setTimeout(10000, () => upstream.destroy(new Error('timeout')));
  upstream.on('error', (err) => {
    if (res.headersSent) {
      res.destroy(err);
    } else {
      res.writeHead(502, { 'content-type': 'text/plain' });
      res.end('Bad Gateway\n');
    }
  });
  // (the client gone before the end: the upstream request too)
  res.on('close', () => { if (!res.writableFinished) upstream.destroy(); });
  upstream.end();
});

server.listen(PORT, '0.0.0.0', () => console.log(`img-proxy: /img/ on ${PORT} -> ${UPSTREAM.host}:${UPSTREAM.port}`));
// pid 1 of its container: node stops on SIGTERM only when it handles it
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
