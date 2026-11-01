import { id as strings } from './strings.js';

const $ = (id) => document.getElementById(id);
const text = (key, values = {}) => (strings[key] ?? strings.unexpected).replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
const encoder = new TextEncoder();
const limit = 9000000000000000n;
const currency = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const definiteCashErrors = new Set(['invalid_cash_entry', 'invalid_payload', 'invalid_request', 'message_too_large', 'insufficient_cash', 'cash_entry_limit', 'shift_required', 'shift_closed', 'shift_not_found', 'idempotency_conflict', 'disk_full', 'database_busy']);
const definitePrintErrors = new Set(['printer_failed', 'printer_unreachable', 'printer_not_found', 'invalid_receipt', 'shift_not_found', 'database_busy', 'database_unavailable', 'disk_full', 'invalid_payload', 'message_too_large']);

function fixed(value) {
  const source = String(value).trim();
  if (!/^\d+$/.test(source) || source.length > 32) throw new Error('invalid_shift');
  const result = BigInt(source);
  if (result > limit) throw new Error('invalid_shift');
  return Number(result);
}

function money(value) {
  return Number.isSafeInteger(value) ? currency.format(value) : text('missingValue');
}

function signedMoney(value) {
  if (!Number.isSafeInteger(value)) return text('missingValue');
  return (value < 0 ? '-' : value > 0 ? '+' : '') + money(Math.abs(value));
}

function dateTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? text('missingValue') : new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

function node(tag, className = '', value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (value !== undefined) element.textContent = String(value);
  return element;
}

function notice(id, key, error = false) {
  const element = $(id);
  element.textContent = key ? text(key) : '';
  element.hidden = !key;
  element.classList.toggle('error', error);
  element.setAttribute('role', error ? 'alert' : 'status');
}

const errorCode = (error) => error?.message ?? 'unexpected';

function validSummary(value) {
  const amounts = ['opening_cash', 'sale_count', 'sales_total', 'cash_sales', 'cash_in', 'cash_out', 'expected_cash'];
  return value && Number.isSafeInteger(value.id) && typeof value.opened_at === 'string' && amounts.every((key) => Number.isSafeInteger(value[key])) &&
    (value.closed_at === null || typeof value.closed_at === 'string') && (value.counted_cash === null || Number.isSafeInteger(value.counted_cash)) &&
    (value.difference === null || Number.isSafeInteger(value.difference)) && typeof value.close_note === 'string' && Array.isArray(value.entries);
}

export function initShift({ request, available }) {
  let current = null;
  let loaded = false;
  let busy = false;
  let sequence = 0;
  let attempt = null;
  let listener = null;
  const isOpen = () => Boolean(current && current.closed_at === null);

  function synchronize() {
    const active = isOpen();
    const enabled = available && !busy;
    $('shift-open-fields').disabled = !enabled;
    $('shift-cash-fields').disabled = !enabled || !active;
    $('shift-close-fields').disabled = !enabled || !active;
    $('shift-refresh').disabled = !enabled;
    $('shift-print').disabled = !enabled || !current;
  }

  function row(key, value, total = false) {
    const element = node('div', total ? 'total-row' : '');
    element.append(node('dt', '', text(key)), node('dd', 'money', value));
    return element;
  }

  function render() {
    const active = isOpen();
    $('shift-open-form').hidden = active;
    $('shift-active').hidden = !current;
    $('shift-cash-card').hidden = !active;
    $('shift-close-card').hidden = !active;
    $('shift-print-card').hidden = !current;
    if (!current) { synchronize(); return; }
    $('shift-state').textContent = text(active ? 'shiftBadgeOpen' : 'shiftBadgeClosed');
    $('shift-state').classList.toggle('closed', !active);
    $('shift-opened').textContent = text('shiftNumber', { id: current.id }) + ' · ' + text('shiftOpenedAt', { time: dateTime(current.opened_at) });
    const summary = $('shift-summary');
    summary.replaceChildren();
    summary.append(row('openingCash', money(current.opening_cash)), row('saleCount', String(current.sale_count)), row('salesTotal', money(current.sales_total)), row('cashSales', money(current.cash_sales)), row('cashInTotal', money(current.cash_in)), row('cashOutTotal', money(current.cash_out)), row('expectedCash', money(current.expected_cash), true));
    if (!active) {
      summary.append(row('shiftClosedAt', dateTime(current.closed_at)), row('countedCash', money(current.counted_cash)), row('difference', signedMoney(current.difference), true));
      if (current.close_note) summary.append(row('closeNote', current.close_note));
    }
    $('shift-closed-copy').hidden = active;
    $('shift-expected').textContent = money(current.expected_cash);
    $('shift-print-hint').textContent = text(active ? 'shiftPrintOpen' : 'shiftPrintClosed');
    const entries = $('shift-entries');
    entries.replaceChildren();
    $('shift-entries-empty').hidden = current.entries.length > 0;
    for (const entry of current.entries) {
      const item = node('li');
      const info = node('div', 'shift-entry-info');
      info.append(node('strong', '', text(entry.kind === 'in' ? 'cashIn' : 'cashOut') + ' · ' + entry.category), node('span', '', dateTime(entry.created_at)));
      if (entry.note) info.append(node('p', 'shift-entry-note', entry.note));
      item.append(info, node('span', 'shift-entry-amount money', signedMoney(entry.kind === 'in' ? entry.amount : -entry.amount)));
      entries.append(item);
    }
    updateDifference();
    synchronize();
    listener?.();
  }

  function applySummary(result) {
    if (!validSummary(result?.shift)) throw new Error('unexpected');
    current = result.shift;
    loaded = true;
    render();
  }

  async function refresh() {
    if (!available || busy) { if (!available) notice('shift-notice', 'desktopRequired'); return; }
    const ticket = ++sequence;
    notice('shift-notice', loaded ? null : 'shiftLoading');
    try {
      const result = await request('shift.current', {});
      if (ticket !== sequence) return;
      if (result?.shift !== null && !validSummary(result?.shift)) throw new Error('unexpected');
      current = result.shift;
      loaded = true;
      notice('shift-notice', null);
      render();
    } catch (error) {
      if (ticket !== sequence) return;
      notice('shift-notice', errorCode(error), true);
      if (!loaded) { current = null; render(); }
    }
  }

  $('shift-refresh').addEventListener('click', refresh);

  $('shift-open-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !available || isOpen()) return;
    let opening;
    try { opening = fixed($('shift-opening-cash').value); }
    catch (error) { notice('shift-notice', errorCode(error), true); return; }
    busy = true;
    notice('shift-notice', 'shiftSaving');
    synchronize();
    try {
      applySummary(await request('shift.open', { opening_cash: opening }));
      attempt = null;
      $('shift-counted').value = '';
      $('shift-close-note').value = '';
      notice('shift-notice', 'shiftOpened');
      notice('shift-close-notice', null);
      notice('shift-print-notice', null);
      $('shift-cash-amount').focus();
    } catch (error) {
      const code = errorCode(error);
      notice('shift-notice', code, true);
      if (code === 'shift_open') await refresh();
    } finally { busy = false; synchronize(); }
  });

  // An uncertain result keeps its entry_key: resubmitting the same form retries the same entry, never a duplicate.
  $('shift-cash-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !available || !isOpen()) return;
    let payload;
    try {
      payload = { kind: document.querySelector('input[name="cash_kind"]:checked').value, amount: fixed($('shift-cash-amount').value), category: $('shift-cash-category').value.trim(), note: $('shift-cash-note').value.trim() };
      if (payload.amount < 1 || !payload.category || encoder.encode(payload.category).length > 64 || encoder.encode(payload.note).length > 160) throw new Error('invalid_cash_entry');
    } catch { notice('shift-cash-notice', 'invalid_cash_entry', true); return; }
    if (!attempt || ['kind', 'amount', 'category', 'note'].some((key) => attempt[key] !== payload[key])) attempt = { ...payload, entry_key: crypto.randomUUID() };
    busy = true;
    notice('shift-cash-notice', 'shiftSaving');
    synchronize();
    try {
      applySummary(await request('shift.cash', attempt));
      attempt = null;
      $('shift-cash-amount').value = '';
      $('shift-cash-category').value = '';
      $('shift-cash-note').value = '';
      notice('shift-cash-notice', 'cashSaved');
      $('shift-cash-amount').focus();
    } catch (error) {
      const code = errorCode(error);
      if (definiteCashErrors.has(code)) attempt = null;
      notice('shift-cash-notice', code, true);
      if (['shift_required', 'shift_closed', 'shift_not_found'].includes(code)) await refresh();
    } finally { busy = false; synchronize(); }
  });

  function updateDifference() {
    let counted = null;
    try { counted = fixed($('shift-counted').value); } catch { counted = null; }
    $('shift-difference').textContent = counted === null || !current ? text('missingValue') : signedMoney(counted - current.expected_cash);
  }
  $('shift-counted').addEventListener('input', updateDifference);

  $('shift-close-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !available || !isOpen()) return;
    let counted;
    try { counted = fixed($('shift-counted').value); }
    catch (error) { notice('shift-close-notice', errorCode(error), true); return; }
    const note = $('shift-close-note').value.trim();
    if (encoder.encode(note).length > 160) { notice('shift-close-notice', 'invalid_shift', true); return; }
    if (!window.confirm(text('shiftCloseConfirm', { amount: money(current.expected_cash) }))) return;
    busy = true;
    notice('shift-close-notice', 'shiftSaving');
    synchronize();
    try {
      applySummary(await request('shift.close', { id: current.id, counted_cash: counted, note }));
      attempt = null;
      notice('shift-close-notice', null);
      notice('shift-notice', 'shiftClosedNotice');
      $('shift-print').focus();
    } catch (error) {
      const code = errorCode(error);
      notice('shift-close-notice', code, true);
      if (['shift_closed', 'shift_not_found'].includes(code)) await refresh();
    } finally { busy = false; synchronize(); }
  });

  // Shift reports carry no audit row or drawer kick, so any failure may simply be retried.
  $('shift-print').addEventListener('click', async () => {
    if (busy || !available || !current) return;
    busy = true;
    notice('shift-print-notice', 'shiftPrinting');
    synchronize();
    try {
      const result = await request('shift.print', { id: current.id });
      if (result?.submitted !== true) throw new Error('unexpected');
      notice('shift-print-notice', 'shiftPrintSent');
    } catch (error) {
      const code = errorCode(error);
      if (code === 'invalid_device_config') notice('shift-print-notice', 'receiptNoPrinter', true);
      else notice('shift-print-notice', definitePrintErrors.has(code) ? 'shiftPrintFailed' : 'shiftPrintUnknown', true);
    } finally { busy = false; synchronize(); }
  });

  for (const key of ['cashCatStock', 'cashCatOwner', 'cashCatCapital', 'cashCatChange']) {
    const option = node('option');
    option.value = text(key);
    $('shift-cash-categories').append(option);
  }
  if (!available) notice('shift-notice', 'desktopRequired');
  synchronize();
  return {
    show: refresh,
    refresh,
    isOpen,
    get loaded() { return loaded; },
    setListener(callback) { listener = callback; },
  };
}
