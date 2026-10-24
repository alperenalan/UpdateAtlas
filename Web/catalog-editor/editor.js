const $ = selector => document.querySelector(selector);
const fields = [...document.querySelectorAll('[data-field]')];
let state;
let selected;
let protectedIDs = new Set();
let dirty = false;

function message(value, kind = '') {
  const node = $('#notice');
  node.textContent = value;
  node.className = kind;
}
function selectedEntry() { return state?.catalog.entries.find(entry => entry === selected); }
function getAt(object, path) { return path.split('.').reduce((value, key) => value?.[key], object); }
function setAt(object, path, value) {
  const keys = path.split('.');
  let target = object;
  for (const key of keys.slice(0, -1)) {
    if (!target[key]) target[key] = {};
    target = target[key];
  }
  target[keys.at(-1)] = value;
}
function label(value) {
  return ({ supported: 'Destekleniyor', managedExternally: 'Haricen yönetiliyor',
    needsCatalog: 'Kaynak aranıyor', unsupported: 'Desteklenmiyor' })[value] ?? value ?? '—';
}
function providerName(entry) {
  const provider = entry.mechanism?.provider ?? entry.mechanism?.providers?.[0];
  return provider?.type ?? (entry.mechanism?.feedURL ? 'Appcast' : '—');
}
function markDirty() {
  if (state.catalog.revision < state.nextRevision) {
    state.catalog.revision = state.nextRevision;
    state.catalog.generatedAt = new Date().toISOString();
  }
  dirty = true;
  $('#revision').textContent = state.catalog.revision;
  $('#rule-count').textContent = state.catalog.entries.length;
  $('#save-state').textContent = 'Kaydedilmedi';
  $('#save-state').style.color = '#af681c';
  message('');
}
function renderRows() {
  const query = $('#search').value.trim().toLocaleLowerCase('tr');
  const status = $('#support-filter').value;
  const rows = state.catalog.entries.filter(entry =>
    (!status || entry.support === status) &&
    (!query || [entry.displayName, entry.publisher, entry.id, entry.mechanism?.name]
      .some(value => (value ?? '').toLocaleLowerCase('tr').includes(query))));
  const body = $('#rows');
  body.replaceChildren();
  const fragment = document.createDocumentFragment();
  for (const entry of rows) {
    const tr = document.createElement('tr');
    tr.tabIndex = 0;
    tr.classList.toggle('selected', entry === selected);
    const app = document.createElement('td');
    const name = document.createElement('span'); name.className = 'app-name'; name.textContent = entry.displayName || 'Adsız kural';
    const id = document.createElement('span'); id.className = 'app-id'; id.textContent = entry.id || 'Yeni ID gerekli';
    app.append(name, id);
    const publisher = document.createElement('td'); publisher.textContent = entry.publisher || '—';
    const support = document.createElement('td');
    const tag = document.createElement('span'); tag.className = `tag ${entry.support || ''}`; tag.textContent = label(entry.support);
    support.append(tag);
    const mechanism = document.createElement('td'); mechanism.textContent = entry.mechanism?.type || '—';
    const provider = document.createElement('td'); provider.textContent = providerName(entry);
    tr.append(app, publisher, support, mechanism, provider);
    tr.addEventListener('click', () => select(entry));
    tr.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(entry); } });
    fragment.append(tr);
  }
  body.append(fragment);
  $('#visible-count').textContent = `${rows.length} / ${state.catalog.entries.length} kural`;
}
function fillDetails() {
  const entry = selectedEntry();
  $('#empty-detail').hidden = !!entry;
  $('#detail').hidden = !entry;
  if (!entry) return;
  $('#detail-title').textContent = entry.displayName || 'Yeni kural';
  $('#detail-id').textContent = entry.id || 'ID henüz girilmedi';
  $('#discard-new').hidden = protectedIDs.has(entry.id);
  for (const field of fields) {
    const path = field.dataset.field;
    const value = getAt(entry, path);
    field.value = field.hasAttribute('data-list') ? (value ?? []).join('\n') : value ?? '';
    field.disabled = path === 'id' && protectedIDs.has(entry.id);
  }
  $('#entry-json').value = JSON.stringify(entry, null, 2);
}
function select(entry) {
  selected = entry;
  renderRows();
  fillDetails();
}
function createSelectOptions(selector, values, blank = false) {
  const node = $(selector);
  if (blank) node.add(new Option('Kaynak yok', ''));
  for (const value of values) node.add(new Option(value, value));
}
function normalizeField(field) {
  if (field.hasAttribute('data-list')) {
    const items = field.value.split('\n').map(value => value.trim()).filter(Boolean);
    return items.length ? items : null;
  }
  const value = field.value.trim();
  if (['id', 'support', 'mechanism.type', 'mechanism.name', 'mechanism.provider.type',
    'mechanism.provider.url'].includes(field.dataset.field)) return value;
  return value || null;
}
function changeField(field) {
  const entry = selectedEntry();
  if (!entry) return;
  const path = field.dataset.field;
  if (path === 'id' && protectedIDs.has(entry.id)) return;
  if (path.startsWith('mechanism.provider.') && !entry.mechanism.provider) {
    if (!field.value.trim()) return;
    entry.mechanism.provider = { type: '', url: '' };
  }
  setAt(entry, path, normalizeField(field));
  if (path === 'mechanism.provider.type' && !field.value) entry.mechanism.provider = null;
  markDirty();
  $('#detail-title').textContent = entry.displayName || 'Yeni kural';
  $('#detail-id').textContent = entry.id || 'ID henüz girilmedi';
  $('#entry-json').value = JSON.stringify(entry, null, 2);
}
async function call(path, catalog = state.catalog) {
  const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json',
    'X-Editor-Token': state.token }, body: JSON.stringify({ catalog,
      sourceDigest: state.sourceDigest, draftDigest: state.draftDigest }) });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}
async function validate() {
  const result = await call('/api/validate');
  const facts = result.facts;
  message(`Geçerli · revizyon ${facts.revision} · ${facts.rules} kural · ${facts.added} yeni · SHA-256 ${facts.sha256.slice(0, 16)}…`, 'success');
  return facts;
}
async function run(task) {
  for (const button of [$('#validate'), $('#save'), $('#export')]) button.disabled = true;
  try { await task(); }
  catch (error) { message(error.message, 'error'); }
  finally { for (const button of [$('#validate'), $('#save'), $('#export')]) button.disabled = false; }
}
function newEntry() {
  return { id: '', displayName: '', publisher: null,
    match: { bundleIdentifiers: null, teamIdentifiers: null, pathSuffixes: null, executableNames: null },
    mechanism: { type: 'unknown', name: 'Bilinmiyor', feedURL: null,
      managerBundleIdentifier: null, provider: null },
    support: 'needsCatalog', vendorURL: null, notes: null };
}

async function initialize() {
  const response = await fetch('/api/state');
  if (!response.ok) throw new Error(`Katalog açılamadı: HTTP ${response.status}`);
  state = await response.json();
  protectedIDs = new Set(state.catalog.entries.map(entry => entry.id));
  createSelectOptions('#mechanism-type', state.mechanismTypes);
  createSelectOptions('#provider-type', state.providerTypes, true);
  $('#source-name').textContent = state.sourceName;
  $('#revision').textContent = state.catalog.revision;
  $('#rule-count').textContent = state.catalog.entries.length;
  $('#save-state').textContent = state.hasDraft ? 'Yerel taslak' : 'Kaynak yüklendi';
  renderRows();
  select(state.catalog.entries[0]);
  if (state.hasDraft) message('Kaydedilmiş yerel taslak açıldı. Kaynak katalog değiştirilmedi.');
  $('#search').addEventListener('input', renderRows);
  $('#support-filter').addEventListener('change', renderRows);
  $('#add').addEventListener('click', () => {
    const entry = newEntry(); state.catalog.entries.unshift(entry); markDirty(); renderRows(); select(entry);
    $('.detail-pane').scrollTop = 0; $('[data-field="id"]').focus();
  });
  $('#discard-new').addEventListener('click', () => {
    if (!selected || protectedIDs.has(selected.id)) return;
    state.catalog.entries = state.catalog.entries.filter(entry => entry !== selected);
    selected = state.catalog.entries[0]; markDirty(); renderRows(); fillDetails();
  });
  for (const field of fields) {
    field.addEventListener('input', () => changeField(field));
    field.addEventListener('change', renderRows);
  }
  $('#apply-json').addEventListener('click', () => {
    try {
      const parsed = JSON.parse($('#entry-json').value);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Kural JSON nesnesi olmalı.');
      if (protectedIDs.has(selected.id) && parsed.id !== selected.id) throw new Error('Mevcut kural ID’si değiştirilemez.');
      const index = state.catalog.entries.indexOf(selected);
      state.catalog.entries[index] = parsed;
      selected = parsed; markDirty(); renderRows(); fillDetails();
      message('Kural JSON’u uygulandı. Kaydetmeden önce katalog doğrulamasını çalıştırın.');
    } catch (error) { message(error.message, 'error'); }
  });
  $('#validate').addEventListener('click', () => run(validate));
  $('#save').addEventListener('click', () => run(async () => {
    const result = await call('/api/save');
    state.draftDigest = result.draftDigest;
    protectedIDs = new Set(state.catalog.entries.map(entry => entry.id));
    dirty = false; $('#save-state').textContent = 'Taslak kaydedildi'; $('#save-state').style.color = '';
    fillDetails();
    message(`Taslak kaydedildi · revizyon ${result.facts.revision} · ${result.facts.rules} kural. Kaynak ve canlı site değişmedi.`, 'success');
  }));
  $('#export').addEventListener('click', () => run(async () => {
    await validate();
    const bytes = `${JSON.stringify(state.catalog, null, 2)}\n`;
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = `catalog-v1-rev${state.catalog.revision}.json`;
    document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }));
  window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
}
initialize().catch(error => message(error.message, 'error'));
