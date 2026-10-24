import assert from 'node:assert/strict';
import test from 'node:test';
import { validateArchiveURL, validateCatalog, validateFeed } from '../validate_channels.mjs';

test('archive hosting allows only exact UpdateAtlas GitHub Releases asset URLs', () => {
  validateArchiveURL('https://github.com/alperenalan/UpdateAtlas/releases/download/v0.1.0/App.zip');
  for (const value of ['http://github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
    'https://github.com/alperenalan/update-atlas/releases/download/v1/App.zip',
    'https://github.com/alperenalan/updateatlas-release/releases/download/v1/App.zip',
    'https://github.com/alperenalan/updateatlas-source/releases/download/v1/App.zip',
    'https://alperenalan.com/downloads/App.zip',
    'https://github.com/another-owner/UpdateAtlas/releases/download/v1/App.zip',
    'https://github.com/alperenalan/UpdateAtlas/archive/refs/tags/App.zip',
    'https://github.com/alperenalan/UpdateAtlas/releases/download/v..1/App.zip',
    'https://github.com.evil.test/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
    'https://github.com:8443/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
    'https://user:password@github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
    'https://github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip?token=x']) assert.throws(() => validateArchiveURL(value));
});

test('channel validation fails closed on unsigned, empty and malformed resources', () => {
  for (const text of ['', '<rss><channel></channel></rss>', 'not xml']) {
    assert.throws(() => validateFeed(Buffer.from(text)));
  }
  for (const text of ['', '{}', '{"schemaVersion":1,"revision":1,"entries":[]}']) {
    assert.throws(() => validateCatalog(Buffer.from(text)));
  }
});

test('catalog validation rejects duplicate identities and insecure providers', () => {
  const rule = { id: 'test', match: { bundleIdentifiers: ['test.app'] },
    mechanism: { type: 'website', name: 'Website', providers: [{ type: 'githubLatestRelease', url: 'https://example.test/releases' }] },
    support: 'supported' };
  const catalog = { schemaVersion: 1, catalogID: 'update-atlas-bootstrap', revision: 12,
    generatedAt: '2026-10-05T00:00:00Z', entries: [rule] };
  assert.deepEqual(validateCatalog(Buffer.from(JSON.stringify(catalog))), { revision: 12, rules: 1 });
  assert.throws(() => validateCatalog(Buffer.from(JSON.stringify({ ...catalog, entries: [rule, rule] }))));
  rule.mechanism.providers[0].url = 'http://example.test/releases';
  assert.throws(() => validateCatalog(Buffer.from(JSON.stringify(catalog))));
});

test('catalog validator uses the public schema and checks current provider fields', () => {
  const rule = { id: 'sample', match: { bundleIdentifiers: ['com.example.app'] },
    mechanism: { type: 'publisherCLIInstaller', name: 'Publisher',
      provider: { type: 'homebrewCask', url: 'https://formulae.brew.sh/api/cask/example.json' } },
    support: 'supported' };
  const catalog = { schemaVersion: 1, catalogID: 'update-atlas-bootstrap', revision: 14,
    generatedAt: '2026-10-05T00:00:00Z', entries: [rule] };
  const check = value => validateCatalog(Buffer.from(JSON.stringify(value)));
  assert.deepEqual(check(catalog), { revision: 14, rules: 1 });
  assert.throws(() => check({ ...catalog, entries: [{ ...rule,
    mechanism: { ...rule.mechanism, provider: { ...rule.mechanism.provider, url: 'http://example.test' } } }] }));
  assert.throws(() => check({ ...catalog, entries: [{ ...rule, unexpected: true }] }));
  assert.throws(() => check({ ...catalog, entries: [{ ...rule,
    mechanism: { ...rule.mechanism, provider: { ...rule.mechanism.provider, url: null } } }] }));
  assert.throws(() => check({ ...catalog, generatedAt: '2999-01-01T00:00:00Z' }));
  assert.throws(() => check({ ...catalog, entries: [{ ...rule,
    match: { executableNames: ['stable-helper'] } }] }));
  assert.deepEqual(check({ ...catalog, entries: [{ ...rule,
    match: { teamIdentifiers: ['TEAM123'], executableNames: ['stable-helper'] } }] }),
  { revision: 14, rules: 1 });
});
