#!/usr/bin/env node
/** Local-only catalog editor. It never writes the source or publishes a site. */
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, rename, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { validateCatalog } from '../../__Assets__/Scripts/validate_channels.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const BUNDLED = resolve(ROOT, 'Apple/UpdateAtlas/Resources/BootstrapCatalog.json');
const SITE = resolve(ROOT, 'Web/site/api/update-atlas/catalog-v1.json');
const DRAFT = resolve(ROOT, '__Assets__/Contentgen/Catalog/private/editor-draft.json');
const LIMIT = 2 * 1024 * 1024;
const ASSETS = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/editor.js', ['editor.js', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
]);

function sha(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
function jsonBytes(value) { return Buffer.from(`${JSON.stringify(value, null, 2)}\n`); }
function fail(message, status = 400) { const error = new Error(message); error.status = status; throw error; }

export function checkCandidate(candidate, source, bundled) {
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) fail('Katalog nesnesi gerekli.');
  const bytes = jsonBytes(candidate);
  let facts;
  try { facts = validateCatalog(bytes); }
  catch (error) { fail(error.message); }
  if (candidate.catalogID !== source.catalogID || candidate.catalogID !== bundled.catalogID) {
    fail('catalogID değiştirilemez. Yeni bir katalog için ayrı geçiş planı gerekir.');
  }
  const changed = !isDeepStrictEqual(candidate, source);
  if (candidate.revision < source.revision) fail('Revizyon yayımlanacak kaynak revizyonundan eski.');
  if (changed && candidate.revision <= source.revision) fail('Değişen katalog için revizyon artırılmalı.');
  if (changed && candidate.revision <= bundled.revision &&
      !isDeepStrictEqual(candidate, bundled)) {
    fail('Değişen katalog, uygulamayla paketlenen revizyondan yüksek olmalı.');
  }
  const nextIDs = new Set(candidate.entries.map(entry => entry.id));
  for (const [name, baseline] of [['kaynak', source], ['paketlenen', bundled]]) {
    const removed = baseline.entries.filter(entry => !nextIDs.has(entry.id));
    if (removed.length) fail(`${name} katalogdaki ID kaldırılamaz: ${removed.slice(0, 5).map(e => e.id).join(', ')}`);
  }
  return { ...facts, bytes: bytes.length, changed,
    added: candidate.entries.length - source.entries.length,
    sha256: sha(bytes) };
}

async function readJSON(path) { return JSON.parse(await readFile(path, 'utf8')); }
async function requestJSON(request) {
  const parts = [];
  let size = 0;
  for await (const part of request) {
    size += part.length;
    if (size > LIMIT + 256 * 1024) fail('İstek çok büyük.', 413);
    parts.push(part);
  }
  try { return JSON.parse(Buffer.concat(parts).toString('utf8')); }
  catch { fail('Geçersiz JSON.'); }
}
function send(response, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length, 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff' });
  response.end(body);
}

export async function createEditor({ sourcePath = existsSync(SITE) ? SITE : BUNDLED,
  draftPath = DRAFT } = {}) {
  sourcePath = resolve(sourcePath);
  draftPath = resolve(draftPath);
  if (sourcePath === draftPath) fail('Kaynak ve taslak aynı dosya olamaz.');
  try { validateCatalog(await readFile(sourcePath)); }
  catch (error) { fail(`Kaynak katalog açılamadı: ${error.message}`); }
  const token = randomBytes(32).toString('hex');
  let address;
  let writeQueue = Promise.resolve();
  const server = createServer(async (request, response) => {
    try {
      const host = request.headers.host;
      if (host !== address && host !== `localhost:${address?.split(':').at(-1)}`) fail('Geçersiz Host.', 403);
      const origin = request.headers.origin;
      if (origin && origin !== `http://${host}`) fail('Geçersiz Origin.', 403);
      const url = new URL(request.url, `http://${host}`);
      if (request.method === 'GET' && ASSETS.has(url.pathname)) {
        const [name, type] = ASSETS.get(url.pathname);
        const body = await readFile(resolve(HERE, name));
        response.writeHead(200, { 'Content-Type': type, 'Content-Length': body.length,
          'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" });
        response.end(body);
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/state') {
        const [sourceBytes, bundled, schema] = await Promise.all([readFile(sourcePath), readJSON(BUNDLED),
          readJSON(resolve(ROOT, '__Assets__/Contentgen/Catalog/catalog-v1.schema.json'))]);
        const source = JSON.parse(sourceBytes);
        const draftBytes = existsSync(draftPath) ? await readFile(draftPath) : null;
        const catalog = draftBytes ? JSON.parse(draftBytes) : source;
        send(response, 200, { catalog, sourceRevision: source.revision,
          bundledRevision: bundled.revision, nextRevision: Math.max(source.revision, bundled.revision) + 1,
          sourceName: sourcePath === SITE ? 'Ürün sitesi kataloğu' : sourcePath === BUNDLED ? 'Paketlenen katalog' : 'Seçilen kaynak',
          sourceDigest: sha(sourceBytes), draftDigest: draftBytes ? sha(draftBytes) : null,
          hasDraft: !!draftBytes, token,
          mechanismTypes: schema.$defs.entry.properties.mechanism.properties.type.enum,
          providerTypes: schema.$defs.versionProvider.properties.type.enum });
        return;
      }
      if (request.method === 'POST' && ['/api/validate', '/api/save'].includes(url.pathname)) {
        if (request.headers['x-editor-token'] !== token) fail('Düzenleyici oturumu geçersiz.', 403);
        const input = await requestJSON(request);
        const [sourceBytes, bundled] = await Promise.all([readFile(sourcePath), readJSON(BUNDLED)]);
        if (input.sourceDigest !== sha(sourceBytes)) fail('Kaynak katalog değişti; sayfayı yenileyip karşılaştırın.', 409);
        const source = JSON.parse(sourceBytes);
        const facts = checkCandidate(input.catalog, source, bundled);
        if (url.pathname === '/api/validate') {
          send(response, 200, { valid: true, facts });
          return;
        }
        const result = await (writeQueue = writeQueue.catch(() => {}).then(async () => {
          const old = existsSync(draftPath) ? await readFile(draftPath) : null;
          if ((old ? sha(old) : null) !== input.draftDigest) fail('Taslak başka bir sekmede değişti; sayfayı yenileyin.', 409);
          await mkdir(dirname(draftPath), { recursive: true });
          const bytes = jsonBytes(input.catalog);
          const temporary = `${draftPath}.${randomUUID()}.tmp`;
          try { await writeFile(temporary, bytes, { flag: 'wx', mode: 0o600 }); await rename(temporary, draftPath); }
          catch (error) { try { await unlink(temporary); } catch {} throw error; }
          return { facts, draftDigest: sha(bytes) };
        }));
        send(response, 200, result);
        return;
      }
      fail('Bulunamadı.', 404);
    } catch (error) {
      send(response, error.status ?? 500, { error: error.status ? error.message : 'Düzenleyici hatası.' });
      if (!error.status) console.error(error);
    }
  });
  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  address = `127.0.0.1:${server.address().port}`;
  return { server, url: `http://${address}/`, sourcePath, draftPath };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 2 && (process.argv.length !== 4 || process.argv[2] !== '--source')) {
    console.error('Kullanım: node Web/catalog-editor/server.mjs [--source KATALOG_JSON]');
    process.exit(2);
  }
  const editor = await createEditor({ sourcePath: process.argv[2] === '--source' ? process.argv[3] : undefined });
  console.log(`Katalog editörü: ${editor.url}`);
  console.log(`Kaynak (salt okunur): ${editor.sourcePath}`);
  console.log(`Taslak: ${editor.draftPath}`);
  console.log('Durdurmak için Ctrl-C. Bu araç yayımlama yapmaz.');
}
