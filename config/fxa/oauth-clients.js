// Writes the OAuth clients Firefox needs (desktop, Android, iOS, the accounts
// settings page) and the Sync scope with its encryption keys (without it the
// accounts pages cannot give Firefox the Sync keys: "OAuth login completed
// without scoped keys") to the file named by $1, taken from the auth server's own
// config/dev.json so they follow upstream, with the redirect URIs pointing to
// this deployment ($CONTENT_SERVER_URL) instead of http://localhost:3030.
// The clients are all public (PKCE), Firefox never sends a secret: the secrets
// published in dev.json are replaced with the hash of a random one nobody knows.
// Run from the fxa-auth-server directory, before bin/key_server.js.
const crypto = require('crypto');
const fs = require('fs');

const CLIENTS = [
  '5882386c6d801776', // Firefox (desktop)
  'a2270f727f45f648', // Fenix (Android)
  '1b1a3e44c54fbb58', // Firefox for iOS
  '3c49430b43dfba77', // Android Components Reference Browser
  'ea3ca969f8c6bb0d', // Firefox Accounts
  '98e6508e88680e1a', // Firefox Accounts Settings
];
const SCOPES = ['https://identity.mozilla.com/apps/oldsync'];
const contentUrl = process.env.CONTENT_SERVER_URL.replace(/\/$/, '');
const dev = JSON.parse(fs.readFileSync('config/dev.json', 'utf-8'));
const clients = dev.oauthServer.clients
  .filter((c) => CLIENTS.includes(c.id))
  .map(({ hashedSecret, hashedSecretPrevious, ...c }) => ({
    ...c,
    hashedSecret: crypto.createHash('sha256').update(crypto.randomBytes(32)).digest('hex'),
    redirectUri: c.redirectUri.split('http://localhost:3030').join(contentUrl),
  }));
const notPublic = clients.filter((c) => !c.publicClient).map((c) => c.id);
if (notPublic.length) {
  console.error(`Expected public OAuth clients only: ${notPublic.join(', ')}`);
  process.exit(1);
}
const missing = CLIENTS.filter((id) => !clients.some((c) => c.id === id));
if (missing.length) {
  console.error(`OAuth clients missing from config/dev.json: ${missing.join(', ')}`);
  process.exit(1);
}
const scopes = dev.oauthServer.scopes.filter((s) => SCOPES.includes(s.scope) && s.hasScopedKeys);
if (scopes.length !== SCOPES.length) {
  console.error(`Scopes with keys missing from config/dev.json: ${SCOPES.join(', ')}`);
  process.exit(1);
}
fs.writeFileSync(process.argv[2], JSON.stringify({ oauthServer: { clients, scopes } }, null, 2));
console.log(`Wrote ${clients.length} OAuth clients and ${scopes.length} scopes for ${contentUrl}`);
