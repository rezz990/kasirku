import { id as strings } from './strings.js';

const $ = (id) => document.getElementById(id);
const text = (key, values = {}) => (strings[key] ?? strings.unexpected).replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
const encoder = new TextEncoder();
const byteLength = (value) => encoder.encode(value).length;
const maxLogoWidth = 384;
const maxLogoHeight = 192;
const maxLogoFile = 5 * 1024 * 1024;
const logoTypes = new Set(['image/png', 'image/jpeg', 'image/bmp', 'image/gif', 'image/webp']);
const columns = { 58: 32, 80: 48 };
// Font A prints 12 dots per character column on both 58 mm (384 dots) and 80 mm (576 dots) paper.
const dotsPerColumn = 12;
const checkboxes = { show_sku: 'device-show-sku', show_barcode: 'device-show-barcode', show_qr: 'device-show-qr', cash_drawer: 'device-cash-drawer', cut_paper: 'device-cut-paper' };
const singleLine = /[\x00-\x1F\x7F]/;
const multiLine = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/;

function node(tag, className = '', value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (value !== undefined) element.textContent = String(value);
  return element;
}

function notice(id, key, error = false, values) {
  const element = $(id);
  element.textContent = key ? text(key, values) : '';
  element.hidden = !key;
  element.classList.toggle('error', error);
  element.setAttribute('role', error ? 'alert' : 'status');
}

function noticeDetail(id, key, code) {
  notice(id, key, true);
  $(id).append(node('span', 'error-detail', text(code)));
}

function errorCode(error) {
  return error?.message ?? 'unexpected';
}

function validLogo(value) {
  return value && Number.isInteger(value.width) && Number.isInteger(value.height) && value.width > 0 && value.height > 0 && value.width <= maxLogoWidth && value.height <= maxLogoHeight && typeof value.bits_base64 === 'string';
}

function decodeBits(base64) {
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

// Atkinson dithering keeps flat logo areas clean while still shading photos on a 1-bit printer.
function dither(data, width, height) {
  const gray = new Float32Array(width * height);
  for (let index = 0; index < gray.length; index++) gray[index] = data[index * 4] * 0.299 + data[index * 4 + 1] * 0.587 + data[index * 4 + 2] * 0.114;
  const ink = new Uint8Array(width * height);
  const spread = [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]];
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const index = y * width + x;
      const value = gray[index] < 128 ? 0 : 255;
      ink[index] = value === 0 ? 1 : 0;
      const error = (gray[index] - value) / 8;
      for (const [dx, dy] of spread) {
        const nx = x + dx;
        const ny = y + dy;
        if (nx >= 0 && nx < width && ny < height) gray[ny * width + nx] += error;
      }
    }
  }
  return ink;
}

function pack(ink, width, height) {
  const rowBytes = Math.ceil(width / 8);
  const bits = new Uint8Array(rowBytes * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) if (ink[y * width + x]) bits[y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
  }
  let binary = '';
  for (const value of bits) binary += String.fromCharCode(value);
  return btoa(binary);
}

async function convertLogo(file) {
  let bitmap;
  try { bitmap = await createImageBitmap(file); } catch { throw new Error('invalid_logo_file'); }
  try {
    if (!bitmap.width || !bitmap.height) throw new Error('invalid_logo_file');
    const scale = Math.min(1, maxLogoWidth / bitmap.width, maxLogoHeight / bitmap.height);
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    context.fillStyle = '#fff';
    context.fillRect(0, 0, width, height);
    context.imageSmoothingQuality = 'high';
    context.drawImage(bitmap, 0, 0, width, height);
    const { data } = context.getImageData(0, 0, width, height);
    return { width, height, bits_base64: pack(dither(data, width, height), width, height) };
  } finally { bitmap.close(); }
}

function logoCanvas(logo) {
  const canvas = document.createElement('canvas');
  canvas.width = logo.width;
  canvas.height = logo.height;
  canvas.className = 'paper-logo';
  canvas.style.width = `${logo.width / dotsPerColumn}ch`;
  canvas.setAttribute('role', 'img');
  canvas.setAttribute('aria-label', text('logoLabel'));
  const context = canvas.getContext('2d');
  const image = context.createImageData(logo.width, logo.height);
  const bits = decodeBits(logo.bits_base64);
  const rowBytes = Math.ceil(logo.width / 8);
  for (let y = 0; y < logo.height; y++) {
    for (let x = 0; x < logo.width; x++) {
      const on = bits[y * rowBytes + (x >> 3)] & (0x80 >> (x & 7));
      const offset = (y * logo.width + x) * 4;
      image.data.fill(on ? 32 : 255, offset, offset + 3);
      image.data[offset + 3] = 255;
    }
  }
  context.putImageData(image, 0, 0);
  return canvas;
}

export function initDevice({ request, available }) {
  const form = $('device-form');
  let loaded = false;
  let loading = false;
  let loadSeq = 0;
  let saving = false;
  let testing = false;
  let detecting = false;
  let logoBusy = false;
  let logo = null;
  let saved = null;
  let baseline = '';
  let previewSeq = 0;
  let previewTimer;
  let scanSeq = 0;
  let scanStart = 0;

  function snapshot() {
    const values = ['device-printer-name', 'device-file-path', 'device-tcp-host', 'device-tcp-port', 'device-header', 'device-footer', 'device-qr-payload', 'device-copies', 'device-feed-lines'].map((id) => $(id).value);
    return JSON.stringify([form.elements.printer_kind.value, form.elements.paper_width.value, ...values, ...Object.values(checkboxes).map((id) => $(id).checked)]);
  }
  const dirty = () => loaded && snapshot() !== baseline;

  function targetReady(config) {
    if (!config) return false;
    if (config.printer_kind === 'spooler') return config.printer_name !== '';
    if (config.printer_kind === 'tcp') return config.tcp_host !== '';
    return config.printer_kind === 'file' && config.file_path !== '';
  }

  function serialize() {
    for (const element of form.querySelectorAll('[aria-invalid="true"]')) element.removeAttribute('aria-invalid');
    const invalid = (id) => {
      $(id).setAttribute('aria-invalid', 'true');
      const error = new Error('invalid_device_config');
      error.field = id;
      return error;
    };
    const integer = (id, minimum, maximum) => {
      const value = $(id).value.trim();
      if (!/^\d{1,5}$/.test(value) || Number(value) < minimum || Number(value) > maximum) throw invalid(id);
      return Number(value);
    };
    const string = (id, maximum, pattern = singleLine) => {
      const value = pattern === singleLine ? $(id).value.trim() : $(id).value;
      if (byteLength(value) > maximum || pattern.test(value)) throw invalid(id);
      return value;
    };
    const config = {
      printer_kind: form.elements.printer_kind.value,
      printer_name: string('device-printer-name', 255),
      file_path: string('device-file-path', 512),
      tcp_host: string('device-tcp-host', 255),
      tcp_port: integer('device-tcp-port', 1, 65535),
      paper_width: Number(form.elements.paper_width.value),
      header: string('device-header', 512, multiLine),
      footer: string('device-footer', 512, multiLine),
      qr_payload: string('device-qr-payload', 512),
      copies: integer('device-copies', 1, 5),
      feed_lines: integer('device-feed-lines', 0, 20),
    };
    for (const [key, id] of Object.entries(checkboxes)) config[key] = $(id).checked;
    if (!['spooler', 'tcp', 'file'].includes(config.printer_kind) || !columns[config.paper_width]) throw new Error('invalid_device_config');
    return config;
  }

  function fillPrinters(printers, keep) {
    const select = $('device-printer-name');
    select.replaceChildren();
    const empty = node('option', '', text('printerChoose'));
    empty.value = '';
    select.append(empty);
    for (const printer of printers) {
      const option = node('option', '', printer.is_default ? text('printerDefault', { name: printer.name }) : printer.name);
      option.value = printer.name;
      select.append(option);
    }
    if (keep && !printers.some((printer) => printer.name === keep)) {
      const option = node('option', '', text('printerMissing', { name: keep }));
      option.value = keep;
      select.append(option);
    }
    select.value = keep;
  }

  function applyConfig(config) {
    for (const radio of form.elements.printer_kind) radio.checked = radio.value === config.printer_kind;
    for (const radio of form.elements.paper_width) radio.checked = Number(radio.value) === config.paper_width;
    fillPrinters([], config.printer_name);
    $('device-file-path').value = config.file_path;
    $('device-tcp-host').value = config.tcp_host;
    $('device-tcp-port').value = String(config.tcp_port);
    $('device-header').value = config.header;
    $('device-footer').value = config.footer;
    $('device-qr-payload').value = config.qr_payload;
    $('device-copies').value = String(config.copies);
    $('device-feed-lines').value = String(config.feed_lines);
    for (const [key, id] of Object.entries(checkboxes)) $(id).checked = config[key] === true;
    saved = config;
    baseline = snapshot();
  }

  function setLogo(value) {
    logo = validLogo(value) ? value : null;
    $('device-logo-status').textContent = logo ? text('logoStored', { width: logo.width, height: logo.height }) : text('logoNone');
  }

  function synchronize() {
    const ready = available && loaded && !loading;
    const kind = form.elements.printer_kind.value;
    $('device-spooler-fields').hidden = kind !== 'spooler';
    $('device-tcp-fields').hidden = kind !== 'tcp';
    $('device-file-fields').hidden = kind !== 'file';
    $('device-fields').disabled = !ready || saving;
    $('device-qr-payload').disabled = !ready || saving || !$('device-show-qr').checked;
    $('device-detect').disabled = !ready || saving || detecting;
    $('device-logo-file').disabled = !ready || saving || logoBusy;
    $('device-logo-pick').classList.toggle('disabled', $('device-logo-file').matches(':disabled'));
    $('device-logo-clear').hidden = !logo;
    $('device-logo-clear').disabled = !ready || saving || logoBusy;
    $('device-reload').hidden = !available || loaded || loading;
    const changed = dirty();
    $('device-save').disabled = !ready || saving || !changed;
    $('device-dirty').textContent = loaded ? text(changed ? 'deviceUnsaved' : 'deviceClean') : '';
    $('device-dirty').classList.toggle('pending', changed);
    const target = targetReady(saved);
    for (const id of ['device-test-print', 'device-test-drawer']) $(id).disabled = !ready || saving || testing || changed || !target;
    $('device-test-hint').textContent = text(!loaded ? 'loadingDevice' : changed ? 'testDirty' : target ? 'testReady' : 'testNoTarget');
    $('scanner-input').disabled = !available;
  }

  function renderPaper(value, width) {
    const paper = $('device-paper');
    paper.replaceChildren();
    paper.classList.remove('stale');
    paper.dataset.width = String(width);
    $('device-preview-width').textContent = text('previewWidth', { width, columns: columns[width] });
    let lines = [];
    let logoPlaced = false;
    const flush = () => {
      if (lines.length) paper.append(node('pre', '', lines.join('\n')));
      lines = [];
    };
    for (const line of value.replace(/\n$/, '').split('\n')) {
      if (line === '[logo]' && logo && !logoPlaced) {
        flush();
        paper.append(logoCanvas(logo));
        logoPlaced = true;
      } else lines.push(line);
    }
    flush();
  }

  function previewFailed(code) {
    $('device-paper').classList.add('stale');
    $('device-paper').setAttribute('aria-busy', 'false');
    noticeDetail('device-preview-notice', 'previewFailed', code);
  }

  function schedulePreview(delay = 200) {
    clearTimeout(previewTimer);
    const sequence = ++previewSeq;
    if (!available || !loaded) return;
    let config;
    try { config = serialize(); } catch (error) { previewFailed(errorCode(error)); return; }
    $('device-paper').setAttribute('aria-busy', 'true');
    previewTimer = setTimeout(async () => {
      try {
        const result = await request('device.preview', config);
        if (sequence !== previewSeq) return;
        if (typeof result?.text !== 'string' || !columns[result.width]) throw new Error('unexpected');
        renderPaper(result.text, result.width);
        notice('device-preview-notice', null);
      } catch (error) {
        if (sequence === previewSeq) previewFailed(errorCode(error));
      } finally {
        if (sequence === previewSeq) $('device-paper').setAttribute('aria-busy', 'false');
      }
    }, delay);
  }

  async function load() {
    if (!available) return;
    const sequence = ++loadSeq;
    loading = true;
    loaded = false;
    notice('device-notice', 'loadingDevice');
    synchronize();
    try {
      const result = await request('device.get');
      if (sequence !== loadSeq) return;
      if (!result?.config || typeof result.config !== 'object' || (result.logo !== null && !validLogo(result.logo))) throw new Error('unexpected');
      applyConfig(result.config);
      setLogo(result.logo);
      loaded = true;
      notice('device-notice', null);
    } catch (error) {
      if (sequence === loadSeq) notice('device-notice', errorCode(error), true);
    } finally {
      if (sequence === loadSeq) {
        loading = false;
        synchronize();
        if (loaded) schedulePreview(0);
      }
    }
  }
  $('device-reload').addEventListener('click', load);

  function changed(event) {
    if (event.target === $('device-logo-file')) return;
    synchronize();
    schedulePreview();
  }
  form.addEventListener('input', changed);
  form.addEventListener('change', changed);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!available || !loaded || saving || !dirty()) return;
    let config;
    try { config = serialize(); } catch (error) {
      notice('device-notice', errorCode(error), true);
      if (error.field) $(error.field).focus();
      return;
    }
    saving = true;
    $('device-save').textContent = text('saving');
    notice('device-notice', null);
    synchronize();
    try {
      const result = await request('device.save', config);
      if (result?.saved !== true) throw new Error('unexpected');
      saved = config;
      baseline = snapshot();
      notice('device-notice', 'deviceSavedNotice');
    } catch (error) {
      notice('device-notice', errorCode(error), true);
    } finally {
      saving = false;
      $('device-save').textContent = text('saveDevice');
      synchronize();
    }
  });

  $('device-detect').addEventListener('click', async () => {
    if (!loaded || detecting || saving) return;
    detecting = true;
    notice('device-printer-notice', 'detectingPrinters');
    synchronize();
    try {
      const result = await request('device.printers');
      if (!Array.isArray(result?.printers)) throw new Error('unexpected');
      const printers = result.printers.filter((printer) => typeof printer?.name === 'string' && printer.name !== '');
      const current = $('device-printer-name').value;
      fillPrinters(printers, current);
      if (!current) {
        const choice = printers.find((printer) => printer.is_default === true) ?? (printers.length === 1 ? printers[0] : null);
        if (choice) $('device-printer-name').value = choice.name;
      }
      if (printers.length) notice('device-printer-notice', 'printersFound', false, { count: printers.length });
      else notice('device-printer-notice', 'noPrinters', true);
    } catch (error) {
      notice('device-printer-notice', errorCode(error), true);
    } finally {
      detecting = false;
      synchronize();
    }
  });

  $('device-logo-file').addEventListener('change', async () => {
    const input = $('device-logo-file');
    const file = input.files?.[0];
    if (!file || !loaded || logoBusy) { input.value = ''; return; }
    if (!logoTypes.has(file.type) || file.size > maxLogoFile) {
      input.value = '';
      notice('device-logo-notice', 'invalid_logo_file', true);
      return;
    }
    logoBusy = true;
    notice('device-logo-notice', 'logoProcessing');
    synchronize();
    try {
      const next = await convertLogo(file);
      const result = await request('device.logo_save', next);
      if (result?.saved !== true) throw new Error('unexpected');
      setLogo(next);
      notice('device-logo-notice', 'logoSaved');
      schedulePreview(0);
    } catch (error) {
      notice('device-logo-notice', errorCode(error), true);
    } finally {
      logoBusy = false;
      input.value = '';
      synchronize();
    }
  });

  $('device-logo-clear').addEventListener('click', async () => {
    if (!loaded || logoBusy || !logo) return;
    logoBusy = true;
    synchronize();
    try {
      const result = await request('device.logo_clear');
      if (result?.saved !== true) throw new Error('unexpected');
      setLogo(null);
      notice('device-logo-notice', 'logoCleared');
      schedulePreview(0);
      $('device-logo-file').focus();
    } catch (error) {
      notice('device-logo-notice', errorCode(error), true);
    } finally {
      logoBusy = false;
      synchronize();
    }
  });

  async function runTest(command, busyKey, doneKey) {
    if (!loaded || testing || saving || dirty()) return;
    testing = true;
    notice('device-test-notice', busyKey);
    synchronize();
    try {
      const result = await request(command);
      if (result?.submitted !== true) throw new Error('unexpected');
      notice('device-test-notice', doneKey);
    } catch (error) {
      notice('device-test-notice', errorCode(error), true);
    } finally {
      testing = false;
      synchronize();
    }
  }
  $('device-test-print').addEventListener('click', () => runTest('device.test_print', 'testPrinting', 'testPrintSent'));
  $('device-test-drawer').addEventListener('click', () => runTest('device.open_drawer', 'drawerOpening', 'drawerSent'));

  $('scanner-input').addEventListener('keydown', (event) => {
    if (event.key.length === 1 && $('scanner-input').value === '') scanStart = performance.now();
  });
  $('scanner-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const code = $('scanner-input').value.trim();
    const elapsed = scanStart ? Math.round(performance.now() - scanStart) : 0;
    $('scanner-input').value = '';
    scanStart = 0;
    if (!code) return;
    const sequence = ++scanSeq;
    const length = [...code].length;
    const result = $('scanner-result');
    result.replaceChildren(node('li', 'scan-code', text('scanCaptured', { code, count: length })));
    // Keyboard-wedge scanners type a whole code in a burst; people rarely stay under ~35 ms per key.
    result.append(node('li', 'muted', text(length >= 4 && elapsed / length < 35 ? 'scanFast' : 'scanSlow', { ms: elapsed })));
    if (!available || byteLength(code) > 120) return;
    const lookup = node('li', 'muted', text('scanLooking'));
    result.append(lookup);
    try {
      const found = await request('product.list', { query: code, offset: 0 });
      if (sequence !== scanSeq) return;
      if (!Array.isArray(found?.products)) throw new Error('unexpected');
      const match = found.products.find((product) => product.barcode === code || product.sku === code);
      lookup.textContent = match ? text('scanMatch', { name: match.name }) : text('scanNoMatch');
      lookup.className = match ? 'scan-match' : 'muted';
    } catch (error) {
      if (sequence === scanSeq) lookup.textContent = text(errorCode(error));
    }
  });

  setLogo(null);
  synchronize();
  return {
    show() {
      notice('device-test-notice', null);
      notice('device-printer-notice', null);
      notice('device-logo-notice', null);
      load();
    },
    canLeave() {
      if (saving || logoBusy) return false;
      return !dirty() || window.confirm(text('discardDevice'));
    },
  };
}
