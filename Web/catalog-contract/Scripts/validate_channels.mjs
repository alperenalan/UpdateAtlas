import crypto from 'node:crypto';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const publicKey = crypto.createPublicKey({
  key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'),
    Buffer.from('1ckmV/xO043m/akIVdWxFXoODdka+37cN4KOv/THLMo=', 'base64')]),
  format: 'der', type: 'spki',
});
const catalogSchema = JSON.parse(fs.readFileSync(new URL('../Contentgen/Catalog/catalog-v1.schema.json', import.meta.url)));
const supportedSchemaKeywords = new Set(['$schema', '$id', '$defs', '$ref', 'title', 'description',
  'type', 'const', 'enum', 'required', 'properties', 'additionalProperties', 'items',
  'minLength', 'maxLength', 'minItems', 'minimum', 'pattern', 'format', 'anyOf', 'allOf',
  'if', 'then', 'else']);
function assertSupportedSchema(schema) {
  for (const [key, value] of Object.entries(schema)) {
    if (!supportedSchemaKeywords.has(key)) throw new Error(`Unsupported catalog schema keyword: ${key}`);
    if (key === 'properties' || key === '$defs') Object.values(value).forEach(assertSupportedSchema);
    if (['items', 'if', 'then', 'else'].includes(key)) assertSupportedSchema(value);
    if (key === 'anyOf' || key === 'allOf') value.forEach(assertSupportedSchema);
  }
}
assertSupportedSchema(catalogSchema);

function validateSchema(value, schema, path = 'catalog') {
  if (schema.$ref) {
    const name = schema.$ref.split('/').at(-1);
    return validateSchema(value, catalogSchema.$defs[name], path);
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const actual = value === null ? 'null' : Array.isArray(value) ? 'array'
      : Number.isInteger(value) ? 'integer' : typeof value;
    if (!types.includes(actual) && !(actual === 'integer' && types.includes('number'))) {
      throw new Error(`${path}: expected ${types.join(' or ')}`);
    }
  }
  if ('const' in schema && value !== schema.const) throw new Error(`${path}: unexpected value`);
  if (schema.enum && !schema.enum.includes(value)) throw new Error(`${path}: unsupported value`);
  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) throw new Error(`${path}: too short`);
    if (schema.maxLength !== undefined && value.length > schema.maxLength) throw new Error(`${path}: too long`);
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) throw new Error(`${path}: invalid format`);
    if (schema.format === 'date-time' &&
        (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(value) ||
         !Number.isFinite(Date.parse(value)))) throw new Error(`${path}: invalid date-time`);
  }
  if (typeof value === 'number' && schema.minimum !== undefined && value < schema.minimum) {
    throw new Error(`${path}: below minimum`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) throw new Error(`${path}: too few items`);
    if (schema.items) value.forEach((item, index) => validateSchema(item, schema.items, `${path}[${index}]`));
  }
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) throw new Error(`${path}.${key}: missing`);
    }
    for (const [key, item] of Object.entries(value)) {
      if (!(key in (schema.properties ?? {}))) {
        if (schema.additionalProperties === false) throw new Error(`${path}.${key}: unknown field`);
      } else validateSchema(item, schema.properties[key], `${path}.${key}`);
    }
  }
  if (schema.anyOf && !schema.anyOf.some(branch => {
    try { validateSchema(value, branch, path); return true; } catch { return false; }
  })) throw new Error(`${path}: no valid alternative`);
  for (const branch of schema.allOf ?? []) validateSchema(value, branch, path);
  if (schema.if) {
    let matched = false;
    try { validateSchema(value, schema.if, path); matched = true; } catch { /* Condition is false. */ }
    if (matched && schema.then) validateSchema(value, schema.then, path);
    if (!matched && schema.else) validateSchema(value, schema.else, path);
  }
}

function validateHTTPS(value, path) {
  if (value == null) return;
  const url = new URL(value);
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) {
    throw new Error(`${path}: insecure URL`);
  }
}

export function validateArchiveURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.hostname !== 'github.com' ||
      url.username || url.password || url.port || url.search || url.hash || !url.pathname.endsWith('.zip')) {
    throw new Error('Untrusted archive URL');
  }
  if (url.pathname.includes('..') || !/^\/alperenalan\/UpdateAtlas\/releases\/download\/[A-Za-z0-9][A-Za-z0-9._-]{0,79}\/[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.zip$/.test(url.pathname)) {
    throw new Error('Archive must belong to the UpdateAtlas GitHub Releases repository');
  }
  return url;
}

export function validateFeed(buffer) {
  const text = buffer.toString('utf8');
  const signature = text.match(/<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: (\d+)\s*-->\s*$/);
  if (!signature || Buffer.byteLength(text.slice(0, signature.index)) !== Number(signature[2]) ||
      !crypto.verify(null, buffer.subarray(0, Number(signature[2])), publicKey, Buffer.from(signature[1], 'base64'))) {
    throw new Error('Missing or invalid appcast signature');
  }
  if (!text.includes('<rss ') || !text.includes('<channel>') || !text.includes('</channel>')) {
    throw new Error('Invalid RSS channel');
  }
  if (text.includes('<sparkle:channel>') || text.includes('criticalUpdate')) {
    throw new Error('Stable release policy requires an explicit review for channels or critical updates');
  }
  const items = [...text.matchAll(/<item>[\s\S]*?<\/item>/g)].map(([value]) => value);
  let previousBuild = Number.POSITIVE_INFINITY;
  for (const item of items) {
    const build = Number(item.match(/<sparkle:version>(\d+)<\/sparkle:version>/)?.[1]);
    if (!Number.isSafeInteger(build) || build <= 0 || build >= previousBuild) {
      throw new Error('Appcast items must have unique decreasing build numbers');
    }
    previousBuild = build;
    const enclosure = item.match(/<enclosure\s+([^>]+)\/?\s*>/)?.[1] ?? '';
    validateArchiveURL(enclosure.match(/\burl="([^"]+)"/)?.[1] ?? '');
    const archiveSignature = enclosure.match(/sparkle:edSignature="([A-Za-z0-9+/=]+)"/)?.[1];
    if (!archiveSignature || Buffer.from(archiveSignature, 'base64').length !== 64 ||
        !(Number(enclosure.match(/\blength="(\d+)"/)?.[1]) > 0)) throw new Error('Unsigned archive');
  }
  return { releases: items.length };
}

export function validateCatalog(buffer) {
  if (buffer.length > 2 * 1024 * 1024) throw new Error('Oversized catalog');
  const catalog = JSON.parse(buffer.toString('utf8'));
  validateSchema(catalog, catalogSchema);
  if (catalog.catalogID !== 'update-atlas-bootstrap' ||
      !Number.isSafeInteger(catalog.revision) || catalog.revision <= 0 ||
      catalog.entries.length === 0 ||
      Date.parse(catalog.generatedAt) > Date.now() + 5 * 60_000) throw new Error('Invalid catalog');
  const ids = new Set();
  for (const entry of catalog.entries) {
    if (!entry.id.trim() || ids.has(entry.id) ||
        (entry.publisher != null && !entry.publisher.trim())) throw new Error('Invalid catalog rule');
    ids.add(entry.id);
    if (!entry.match.bundleIdentifiers?.length && !entry.match.teamIdentifiers?.length) {
      throw new Error(`Rule ${entry.id}: fallback identity requires a signing team`);
    }
    for (const values of Object.values(entry.match)) {
      if (values?.some(value => !value.trim())) throw new Error(`Rule ${entry.id}: blank match identity`);
    }
    const providers = [entry.mechanism.provider, ...(entry.mechanism.providers ?? [])].filter(Boolean);
    if (providers.some(provider => provider.type === 'platformDownloadPage' &&
        (!provider.targetPlatform || provider.targetPlatform.length > 40 ||
         !provider.versionRegex || provider.versionRegex.length > 200 ||
         !/\((?!\?)/.test(provider.versionRegex)))) throw new Error('Invalid platform provider');
    const urls = [entry.vendorURL, entry.sourceCodeURL, entry.releaseNotesURL, entry.mechanism.feedURL,
      ...providers.map(provider => provider.url)];
    urls.forEach((value, index) => validateHTTPS(value, `rule ${entry.id} URL ${index}`));
  }
  return { revision: catalog.revision, rules: catalog.entries.length };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: node validate_channels.mjs APPCAST_XML CATALOG_JSON');
    console.log(JSON.stringify({ appcast: validateFeed(fs.readFileSync(process.argv[2])),
      catalog: validateCatalog(fs.readFileSync(process.argv[3])) }));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
