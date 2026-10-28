import { id as strings } from './strings.js';
import { initPOS } from './pos.js';

const text = (key) => strings[key] ?? strings.unexpected;
for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = text(element.dataset.i18n);
for (const element of document.querySelectorAll('[data-i18n-placeholder]')) element.placeholder = text(element.dataset.i18nPlaceholder);
for (const element of document.querySelectorAll('[data-i18n-aria]')) element.setAttribute('aria-label', text(element.dataset.i18nAria));

const bridge = window.chrome?.webview;
const pending = new Map();
const form = document.querySelector('#business-form');
const fields = document.querySelector('#form-fields');
const save = document.querySelector('#save');
const check = document.querySelector('#check');
const notice = document.querySelector('#notice');
const connection = document.querySelector('#connection');
const savedView = document.querySelector('#saved-view');
const setup = document.querySelector('#setup');
let needsInitialLoad = true;
let loading = false;

function announce(key, isError = false) {
  notice.textContent = text(key);
  notice.hidden = false;
  notice.classList.toggle('error', isError);
  notice.setAttribute('role', isError ? 'alert' : 'status');
}

function request(command, payload = {}) {
  if (!bridge) return Promise.reject(new Error('desktopRequired'));
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')); }, 10000);
    pending.set(id, { resolve, reject, timer });
    try {
      bridge.postMessage({ id, command, payload });
    } catch {
      clearTimeout(timer);
      pending.delete(id);
      reject(new Error('unexpected'));
    }
  });
}

bridge?.addEventListener('message', ({ data }) => {
  if (!data || typeof data.id !== 'string' || typeof data.ok !== 'boolean') return;
  const entry = pending.get(data.id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(data.id);
  if (data.ok) entry.resolve(data.result);
  else entry.reject(new Error(data.error?.code ?? 'unexpected'));
});

const pos = initPOS({ request, available: Boolean(bridge) });

function showBusiness(value) {
  document.querySelector('#business-name').value = value.name;
  document.querySelector('#business-address').value = value.address;
  for (const radio of form.elements.mode) radio.checked = radio.value === value.mode;
  document.querySelector('#saved-name').textContent = value.name;
  document.querySelector('#saved-mode').textContent = text({ retail: 'retailLabel', food: 'foodLabel', service: 'serviceLabel' }[value.mode]);
  document.querySelector('#saved-address').textContent = value.address || text('noAddress');
  form.hidden = true;
  savedView.hidden = false;
  pos.setBusiness(value);
}

async function load() {
  loading = true;
  setup.setAttribute('aria-busy', 'true');
  try {
    const status = await request('app.status');
    needsInitialLoad = false;
    connection.textContent = text('connected');
    connection.classList.add('online');
    fields.disabled = false;
    notice.hidden = true;
    if (status.business) showBusiness(status.business);
  } catch (error) {
    announce(error.message, true);
  } finally {
    loading = false;
    setup.setAttribute('aria-busy', 'false');
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (fields.disabled) return;
  const data = new FormData(form);
  const value = { name: String(data.get('name')).trim(), mode: String(data.get('mode')), address: String(data.get('address')).trim() };
  if (!value.name || new TextEncoder().encode(value.name).length > 120 || new TextEncoder().encode(value.address).length > 512) {
    announce('invalid_business', true);
    document.querySelector('#business-name').focus();
    return;
  }
  fields.disabled = true;
  setup.setAttribute('aria-busy', 'true');
  save.querySelector('span').textContent = text('saving');
  notice.hidden = true;
  try {
    await request('business.save', value);
    showBusiness(value);
    document.querySelector('#open-cashier').focus();
  } catch (error) {
    announce(error.message, true);
  } finally {
    fields.disabled = false;
    setup.setAttribute('aria-busy', 'false');
    save.querySelector('span').textContent = text('saveButton');
  }
});

document.querySelector('#edit').addEventListener('click', () => {
  savedView.hidden = true;
  form.hidden = false;
  notice.hidden = true;
  document.querySelector('#business-name').focus();
});

check.addEventListener('click', async () => {
  if (loading) return;
  check.disabled = true;
  const result = document.querySelector('#diagnostic-result');
  result.textContent = text('checking');
  try {
    await request('system.ping');
    result.textContent = text('checkSuccess');
    if (needsInitialLoad) await load();
  } catch (error) {
    result.textContent = text(error.message);
  } finally {
    check.disabled = false;
  }
});

if (bridge) {
  check.disabled = false;
  await load();
} else {
  connection.textContent = text('disconnected');
  setup.setAttribute('aria-busy', 'false');
  announce('desktopRequired');
}
