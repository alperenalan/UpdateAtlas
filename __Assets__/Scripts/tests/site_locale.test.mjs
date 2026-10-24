import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../../Web/site/site.js', import.meta.url), 'utf8');

function visit({ path = '/', languages = ['en'], saved = {} } = {}) {
  const state = { ...saved };
  let destination = null;
  let click = null;
  const document = {
    documentElement: { dataset: {} },
    querySelectorAll() { return []; },
    querySelector() { return path === '/' || path === '/index.html' ? null : { addEventListener(_, handler) { click = handler; } }; },
  };
  const context = {
    document,
    navigator: { languages },
    location: {
      pathname: path,
      search: '?from=test',
      hash: '#features',
      replace(value) { destination = value; },
    },
    localStorage: {
      getItem(key) { return state[key] ?? null; },
      setItem(key, value) { state[key] = value; },
    },
    matchMedia() { return { matches: false }; },
    module: { exports: {} },
  };
  vm.runInNewContext(source, context);
  return { destination, click, state, document, api: context.module.exports };
}

test('root chooses supported browser language, including regional variants', () => {
  assert.equal(visit({ languages: ['tr-TR', 'en-US'] }).destination, '/tr/?from=test#features');
  assert.equal(visit({ languages: ['zh-CN', 'en-US'] }).destination, '/zh-Hans/?from=test#features');
  assert.equal(visit({ languages: ['zh-TW', 'ja-JP'] }).destination, '/ja/?from=test#features');
  assert.equal(visit({ languages: ['it-IT'] }).destination, '/en/?from=test#features');
  assert.equal(visit({ path: '/index.html', languages: ['de-DE'] }).destination, '/de/?from=test#features');
});

test('manual language choice persists and localized pages do not redirect', () => {
  assert.equal(visit({ languages: ['tr'], saved: { 'updateatlas-locale': 'fr' } }).destination, '/fr/?from=test#features');
  assert.equal(visit({ path: '/de/', languages: ['tr'] }).destination, null);
});

test('theme toggle overrides system choice and persists', () => {
  const page = visit({ path: '/en/' });
  page.click();
  assert.equal(page.document.documentElement.dataset.theme, 'dark');
  assert.equal(page.state['updateatlas-theme'], 'dark');
  page.click();
  assert.equal(page.document.documentElement.dataset.theme, 'light');
});
