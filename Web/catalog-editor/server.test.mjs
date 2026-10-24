import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createEditor, checkCandidate } from './server.mjs';

const root = resolve(import.meta.dirname, '../..');
const bundledPath = resolve(root, 'Apple/UpdateAtlas/Resources/BootstrapCatalog.json');
const scratch = resolve(root, '.temporary_files');

test('editor keeps source untouched and rejects rollback, removed IDs and concurrent draft overwrite', async () => {
  await mkdir(scratch, { recursive: true });
  const dir = await mkdtemp(resolve(scratch, 'catalog-editor-test-'));
  const sourcePath = resolve(dir, 'source.json');
  const draftPath = resolve(dir, 'draft.json');
  const original = await readFile(bundledPath);
  await writeFile(sourcePath, original);
  const source = JSON.parse(original);
  const editor = await createEditor({ sourcePath, draftPath });
  try {
    const stateResponse = await fetch(`${editor.url}api/state`);
    const state = await stateResponse.json();
    assert.equal(state.catalog.revision, source.revision);
    assert.equal(state.catalog.entries.length, source.entries.length);
    assert.equal(state.hasDraft, false);
    const candidate = structuredClone(source);
    candidate.revision += 1;
    candidate.generatedAt = new Date().toISOString();
    candidate.entries[0].notes = 'Reviewed candidate note';
    assert.equal(checkCandidate(candidate, source, source).changed, true);
    assert.throws(() => checkCandidate({ ...candidate, revision: source.revision }, source, source), /revizyon/i);
    assert.throws(() => checkCandidate({ ...candidate, entries: candidate.entries.slice(1) }, source, source), /ID kaldırılamaz/);
    const request = async (path, body, headers = {}) => fetch(`${editor.url}api/${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Editor-Token': state.token, ...headers },
      body: JSON.stringify(body),
    });
    const payload = { catalog: candidate, sourceDigest: state.sourceDigest, draftDigest: null };
    assert.equal((await request('save', payload, { Origin: 'https://attacker.example' })).status, 403);
    assert.equal((await fetch(`${editor.url}api/save`, { method: 'POST', body: JSON.stringify(payload) })).status, 403);
    const saved = await request('save', payload);
    assert.equal(saved.status, 200);
    const savedBody = await saved.json();
    assert.equal(savedBody.facts.revision, candidate.revision);
    assert.equal((await request('save', payload)).status, 409);
    assert.deepEqual(await readFile(sourcePath), original);
    assert.deepEqual(JSON.parse(await readFile(draftPath)), candidate);
  } finally {
    await new Promise((resolveClose, reject) => editor.server.close(error => error ? reject(error) : resolveClose()));
    await rm(dir, { recursive: true, force: true });
  }
});
