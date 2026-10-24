import crypto from 'node:crypto';
import fs from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { validateCatalog } from './validate_channels.mjs';

// This file and its v1 contract are staged into the product-site Web directory.
// Cloudflare Pages runs it before building, so a changed public JSON requires
// a matching reviewed staging manifest.
const catalog = fs.readFileSync(new URL('../../site/api/update-atlas/catalog-v1.json', import.meta.url));
const manifest = JSON.parse(fs.readFileSync(new URL('../manifest.json', import.meta.url)));
const bundled = JSON.parse(fs.readFileSync(new URL('../Contentgen/Catalog/BootstrapCatalog.json', import.meta.url)));
for (const [relative, expectedFile] of Object.entries(manifest.catalog_contract)) {
  const bytes = fs.readFileSync(new URL(`../${relative}`, import.meta.url));
  if (bytes.length !== expectedFile.bytes ||
      crypto.createHash('sha256').update(bytes).digest('hex') !== expectedFile.sha256) {
    throw new Error(`Catalog contract differs from staging manifest: ${relative}`);
  }
}
const facts = validateCatalog(catalog);
const expected = manifest.catalog;
const digest = crypto.createHash('sha256').update(catalog).digest('hex');
if (digest !== expected.sha256 || catalog.length !== expected.bytes ||
    facts.revision !== expected.revision || facts.rules !== expected.rules) {
  throw new Error('The site catalog differs from its reviewed staging manifest');
}
const candidate = JSON.parse(catalog);
if (candidate.catalogID === bundled.catalogID && candidate.revision >= bundled.revision) {
  const candidateIDs = new Set(candidate.entries.map(entry => entry.id));
  const removed = bundled.entries.find(entry => !candidateIDs.has(entry.id));
  if (removed) throw new Error(`The site catalog removed bundled rule ${removed.id}`);
  if (candidate.revision === bundled.revision && !isDeepStrictEqual(candidate, bundled)) {
    throw new Error('The site catalog changed bundled content without increasing revision');
  }
}
console.log(JSON.stringify({ catalog: facts, sha256: digest }));
