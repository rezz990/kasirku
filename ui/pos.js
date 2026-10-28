import { id as strings } from './strings.js';

const $ = (id) => document.getElementById(id);
const text = (key, values = {}) => (strings[key] ?? strings.unexpected).replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
const encoder = new TextEncoder();
const limit = 9000000000000000n;
const currency = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const totalsKeys = ['gross', 'line_discount', 'subtotal', 'transaction_discount', 'net_subtotal', 'service_charge', 'tax_base', 'tax', 'total_before_rounding', 'rounding_adjustment', 'total'];
const safeCheckoutErrors = new Set(['invalid_cart', 'invalid_discount', 'product_changed', 'product_not_found', 'insufficient_stock', 'underpayment', 'total_changed', 'disk_full', 'database_busy', 'business_required', 'invalid_payload', 'invalid_request', 'message_too_large']);
// These fail before any byte reaches the printer; everything else may have printed.
const definitePrintErrors = new Set(['printer_failed', 'printer_unreachable', 'printer_not_found', 'invalid_receipt', 'sale_not_found', 'database_busy', 'database_unavailable', 'disk_full', 'invalid_payload', 'message_too_large']);

function fixed(value, digits, maximum = limit, code = 'invalidMoney') {
  const source = String(value).trim().replace(',', '.');
  const pattern = digits ? new RegExp(`^\\d+(?:\\.\\d{1,${digits}})?$`) : /^\d+$/;
  if (!pattern.test(source) || source.length > 32) throw new Error(code);
  const [whole, fraction = ''] = source.split('.');
  const result = BigInt(whole) * (10n ** BigInt(digits)) + BigInt(fraction.padEnd(digits, '0') || '0');
  if (result > maximum) throw new Error(code);
  return Number(result);
}

function decimal(value, digits = 3) {
  if (!Number.isSafeInteger(value)) return text('missingValue');
  const source = String(value).padStart(digits + 1, '0');
  const fraction = source.slice(-digits).replace(/0+$/, '');
  return source.slice(0, -digits) + (fraction ? `,${fraction}` : '');
}

function money(value) {
  return Number.isSafeInteger(value) ? currency.format(value) : text('missingValue');
}

function dateTime(value) {
  const date = new Date(typeof value === 'number' && value < 100000000000 ? value * 1000 : value);
  return Number.isNaN(date.getTime()) ? text('missingValue') : new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

function node(tag, className = '', value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (value !== undefined) element.textContent = String(value);
  return element;
}

function button(key, className, handler, values) {
  const element = node('button', className, text(key, values));
  element.type = 'button';
  element.addEventListener('click', handler);
  return element;
}

function notice(id, key, error = false, values) {
  const element = $(id);
  element.textContent = key ? text(key, values) : '';
  element.hidden = !key;
  element.classList.toggle('error', error);
  element.setAttribute('role', error ? 'alert' : 'status');
  element.dataset.errorKey = key ?? '';
}

function noticeDetail(id, key, code) {
  notice(id, key, true);
  $(id).append(node('span', 'error-detail', text(code)));
}

function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

function validTotals(totals) {
  return totals && totalsKeys.every((key) => Number.isSafeInteger(totals[key]) && Math.abs(totals[key]) <= Number(limit) && (key === 'rounding_adjustment' || totals[key] >= 0));
}

function renderTotals(container, totals, compact = false) {
  container.replaceChildren();
  if (!totals) return;
  const keys = compact ? totalsKeys.filter((key) => key === 'subtotal' || key === 'total' || (['line_discount', 'transaction_discount', 'service_charge', 'tax', 'rounding_adjustment'].includes(key) && totals[key] !== 0)) : totalsKeys;
  for (const key of keys) {
    const row = node('div', key === 'total' ? 'total-row' : '');
    row.dataset.totalKey = key;
    row.append(node('dt', '', text(key)), node('dd', 'money', money(totals[key])));
    container.append(row);
  }
}

function renderReceipt(container, sale) {
  container.replaceChildren();
  const receipt = node('article', 'receipt');
  receipt.dataset.saleId = String(sale.id);
  receipt.append(node('h3', 'receipt-business', sale.business_name), node('p', 'receipt-address', sale.business_address || text('noAddress')), node('span', 'paid-badge', text('paidBadge')));
  const metadata = node('dl', 'receipt-metadata');
  for (const [key, value] of [['receiptNumber', sale.number], ['receiptDate', dateTime(sale.created_at)]]) {
    const row = node('div');
    row.append(node('dt', '', text(key)), node('dd', '', value));
    metadata.append(row);
  }
  receipt.append(metadata, node('h4', '', text('receiptItems')));
  const items = node('ul', 'receipt-items');
  for (const item of sale.items) {
    const row = node('li');
    if (item.product_id != null) row.dataset.productId = String(item.product_id);
    const heading = node('div', 'receipt-item-heading');
    heading.append(node('strong', '', item.name), node('span', 'money', money(item.net)));
    row.append(heading, node('p', 'muted', text('receiptQuantity', { quantity: decimal(item.quantity_milli), unit: item.unit, price: money(item.unit_price) })));
    if (item.discount > 0) row.append(node('p', 'muted', text('receiptDiscount', { amount: money(item.discount) })));
    if (item.note) row.append(node('p', 'receipt-note', text('receiptNote', { note: item.note })));
    items.append(row);
  }
  const totals = node('dl', 'totals receipt-totals');
  renderTotals(totals, sale.totals, true);
  const cash = node('dl', 'totals receipt-cash');
  for (const [key, value] of [['receiptTendered', sale.tendered], ['change', sale.change]]) {
    const row = node('div');
    row.append(node('dt', '', text(key)), node('dd', 'money', money(value)));
    cash.append(row);
  }
  receipt.append(items, totals, cash);
  container.append(receipt);
}

export function initPOS({ request, available, device }) {
  let business = null;
  let screen = 'business';
  let products = [];
  let catalogOffset = 0;
  let catalogPrevious = [];
  let catalogHasMore = false;
  let catalogBusy = false;
  let catalogSeq = 0;
  let catalogLoadedSeq = 0;
  let catalogError = false;
  let searchTimer;
  let editing = null;
  let editorBaseline = '';
  let editorBusy = false;
  let lines = [];
  let lineSerial = 0;
  let quote = null;
  let quoteBusy = false;
  let quoteSeq = 0;
  let quoteTimer;
  let quoteError = null;
  const changedProducts = new Map();
  let historyOffset = 0;
  let historyHasMore = false;
  let historyBusy = false;
  let historySeq = 0;
  let selectedSale = null;
  let receiptSeq = 0;
  let attempt = null;
  let checkoutBusy = false;
  let checkoutUncertain = false;
  let paymentRepair = false;
  let paymentTotal = null;
  let paid = false;
  let printSale = null;
  let printSeq = 0;
  let printBusy = false;
  let reprintBusy = false;
  const dialog = $('payment-dialog');
  const locked = () => checkoutBusy || checkoutUncertain;
  const editableCart = () => available && business && !locked() && !dialog.open;
  const errorCode = (error) => error?.message ?? 'unexpected';

  function synchronize() {
    for (const nav of document.querySelectorAll('[data-nav]')) {
      nav.disabled = locked() || (nav.dataset.nav !== 'business' && (!available || !business));
      if (nav.dataset.nav === screen) nav.setAttribute('aria-current', 'page');
      else nav.removeAttribute('aria-current');
    }
    $('open-cashier').disabled = !available || !business || locked();
    $('add-product').disabled = !available || !business || locked() || editorBusy;
    $('product-search').disabled = !available || locked();
    $('catalog-prev').disabled = !available || locked() || catalogBusy || !catalogPrevious.length;
    $('catalog-next').disabled = !available || locked() || catalogBusy || !catalogHasMore;
    $('catalog-empty-action').disabled = !available || locked();
    $('cart-clear').disabled = !editableCart() || !lines.length;
    $('transaction-fields').disabled = !editableCart();
    $('transaction-discount-value').disabled = !editableCart() || $('transaction-discount-kind').value === 'none';
    $('pay').disabled = !editableCart() || !lines.length || quoteBusy || !quote || Boolean(quoteError);
    $('quote-retry').disabled = !editableCart() || quoteBusy;
    $('product-fields').disabled = !available || locked() || editorBusy;
    $('product-close').disabled = locked() || editorBusy;
    $('product-stock').disabled = !available || locked() || editorBusy || !$('product-track-stock').checked;
    $('history-date').disabled = !available || locked();
    $('history-all').disabled = !available || locked();
    $('history-prev').disabled = !available || locked() || historyBusy || historyOffset === 0;
    $('history-next').disabled = !available || locked() || historyBusy || !historyHasMore;
    for (const control of document.querySelectorAll('#product-list button, #cart-lines button, #cart-lines input, #cart-lines select, #cart-lines textarea, #sale-list button')) {
      control.disabled = !available || !business || locked() || (control.closest('#cart-lines') && (dialog.open || (control.dataset.blocked === 'true' && control.dataset.action !== 'remove')));
      if (control.dataset.soldOut === 'true' && control.dataset.action === 'add') control.disabled = true;
    }
    for (const line of lines) {
      const input = $(`line-${line.serial}-discount-value`);
      if (input) input.disabled = !editableCart() || line.blocked || line.kind === 'none';
    }
    for (const id of ['business-screen', 'pos-screen', 'history-screen', 'device-screen']) $(id).inert = locked();
    $('receipt-reprint').disabled = !available || locked() || reprintBusy;
    $('print-retry').disabled = printBusy;
    $('print-copy').disabled = printBusy;
    $('payment-fields').disabled = locked() || paymentRepair;
    $('payment-cancel').disabled = locked();
    $('checkout-retry').hidden = !checkoutUncertain || checkoutBusy;
    $('checkout-retry').disabled = checkoutBusy;
    $('payment-submit').hidden = checkoutUncertain;
    updateTender();
  }

  function editorValues() {
    return JSON.stringify(['name', 'sku', 'barcode', 'category', 'unit', 'price', 'cost', 'stock'].map((key) => $(`product-${key}`).value).concat($('product-track-stock').checked));
  }

  function discardEditor() {
    if (editorBusy) return false;
    if (!$('product-form').hidden && editorValues() !== editorBaseline && !window.confirm(text('discardProduct'))) return false;
    $('product-form').hidden = true;
    $('product-editor-empty').hidden = false;
    editing = null;
    return true;
  }

  function navigate(next) {
    if (locked() || dialog.open || (available && !business && next !== 'business')) return;
    if (screen === 'device' && next !== 'device' && !device.canLeave()) return;
    if (next !== screen && !discardEditor()) return;
    const previous = screen;
    screen = next;
    $('business-screen').hidden = next !== 'business';
    $('pos-screen').hidden = next !== 'cashier' && next !== 'products';
    $('history-screen').hidden = next !== 'history';
    $('device-screen').hidden = next !== 'device';
    $('cart-panel').hidden = next !== 'cashier';
    $('product-editor-panel').hidden = next !== 'products';
    $('pos-screen').classList.toggle('product-mode', next === 'products');
    $('catalog-title').textContent = text(next === 'products' ? 'productsTitle' : 'catalogTitle');
    $('catalog-copy').textContent = text(next === 'products' ? 'productsCopy' : 'catalogCopy');
    synchronize();
    if (next === 'cashier' || next === 'products') {
      renderProducts();
      loadProducts();
      $('product-search').focus();
    } else if (next === 'history') {
      loadHistory();
      $('history-title').focus();
    } else if (next === 'device') {
      // Reloading while already on the screen would silently drop unsaved settings.
      if (previous !== 'device') device.show();
      $('device-title').focus();
    }
  }

  for (const nav of document.querySelectorAll('[data-nav]')) nav.addEventListener('click', () => navigate(nav.dataset.nav));
  $('open-cashier').addEventListener('click', () => navigate('cashier'));
  $('device-edit-business').addEventListener('click', () => {
    navigate('business');
    if (screen === 'business') ($('saved-view').hidden ? $('business-name') : $('edit')).focus();
  });

  function catalogState(key, error = false) {
    notice('catalog-notice', key, error);
    $('catalog-empty').hidden = false;
    $('catalog-empty-title').textContent = text(error ? 'catalogFailed' : key);
    $('catalog-empty-copy').textContent = text(error ? key : 'noProductsCopy');
    $('catalog-empty-action').hidden = !error;
    $('catalog-empty-action').textContent = text('retry');
  }

  function renderProducts() {
    $('product-list').replaceChildren();
    for (const product of products) {
      const card = node('article', 'product-card');
      card.dataset.productId = String(product.id);
      card.dataset.revision = String(product.revision);
      const heading = node('div', 'product-card-heading');
      heading.append(node('h3', '', product.name), node('span', 'product-category', product.category || product.unit));
      const stock = product.stock_milli === null ? text('untracked') : text(product.stock_milli === 0 ? 'soldOut' : 'stockValue', { quantity: decimal(product.stock_milli), unit: product.unit });
      card.append(heading, node('p', 'product-code', product.sku || product.barcode || text('noCode')), node('strong', 'product-price money', money(product.price)), node('p', product.stock_milli === 0 ? 'stock sold-out' : 'stock', stock));
      const actions = node('div', 'product-actions');
      const edit = button('editProduct', 'plain-button', () => openEditor(product));
      edit.dataset.action = 'edit';
      edit.dataset.productId = String(product.id);
      edit.setAttribute('aria-label', text('editNamedProduct', { name: product.name }));
      actions.append(edit);
      if (screen === 'cashier') {
        const add = button('add', 'secondary-button compact', () => addProduct(product));
        add.dataset.action = 'add';
        add.dataset.productId = String(product.id);
        add.dataset.soldOut = String(product.stock_milli === 0);
        add.setAttribute('aria-label', text('addToCart', { name: product.name }));
        actions.append(add);
      }
      card.append(actions);
      $('product-list').append(card);
    }
    $('catalog-count').textContent = text('catalogCount', { count: products.length });
    $('catalog-page').textContent = text('page', { page: catalogPrevious.length + 1 });
    $('catalog-empty').hidden = products.length > 0;
    if (!products.length && !catalogBusy && !catalogError) {
      const searching = $('product-search').value.trim() !== '';
      $('catalog-empty-title').textContent = text(searching ? 'noMatches' : 'noProducts');
      $('catalog-empty-copy').textContent = text(searching ? 'noMatchesCopy' : 'noProductsCopy');
      $('catalog-empty-action').hidden = false;
      $('catalog-empty-action').textContent = text(searching ? 'clearSearch' : 'addProduct');
    }
    synchronize();
  }

  async function loadProducts() {
    if (locked()) return;
    clearTimeout(searchTimer);
    const sequence = ++catalogSeq;
    catalogError = false;
    products = [];
    catalogHasMore = false;
    if (!available) {
      renderProducts();
      catalogState('desktopRequired', true);
      synchronize();
      return;
    }
    if (!business) return;
    catalogBusy = true;
    renderProducts();
    catalogState('loadingProducts');
    $('catalog-content').setAttribute('aria-busy', 'true');
    synchronize();
    try {
      const query = $('product-search').value.trim();
      if (encoder.encode(query).length > 120) throw new Error('invalid_query');
      const result = await request('product.list', { query, offset: catalogOffset });
      if (sequence !== catalogSeq) return;
      if (!Array.isArray(result?.products) || typeof result.has_more !== 'boolean') throw new Error('unexpected');
      products = result.products;
      catalogHasMore = result.has_more;
      catalogLoadedSeq = sequence;
      notice('catalog-notice', null);
    } catch (error) {
      if (sequence !== catalogSeq) return;
      catalogError = true;
      catalogState(errorCode(error), true);
    } finally {
      if (sequence === catalogSeq) {
        catalogBusy = false;
        $('catalog-content').setAttribute('aria-busy', 'false');
        renderProducts();
        if (catalogError) catalogState($('catalog-notice').dataset.errorKey || 'unexpected', true);
      }
    }
  }

  function resetSearch() {
    if (locked()) return;
    catalogOffset = 0;
    catalogPrevious = [];
    loadProducts();
  }
  $('search-form').addEventListener('submit', (event) => { event.preventDefault(); resetSearch(); });
  $('product-search').addEventListener('input', () => {
    if (locked()) return;
    ++catalogSeq;
    clearTimeout(searchTimer);
    products = [];
    catalogHasMore = false;
    renderProducts();
    searchTimer = setTimeout(resetSearch, 180);
  });
  $('catalog-prev').addEventListener('click', () => {
    if (locked() || catalogBusy || !catalogPrevious.length) return;
    catalogOffset = catalogPrevious.pop();
    loadProducts();
  });
  $('catalog-next').addEventListener('click', () => {
    if (locked() || catalogBusy || !catalogHasMore || !products.length) return;
    catalogPrevious.push(catalogOffset);
    catalogOffset += products.length;
    loadProducts();
  });
  $('catalog-empty-action').addEventListener('click', () => {
    if (locked() || !available) return;
    if (catalogError) loadProducts();
    else if ($('product-search').value.trim()) { $('product-search').value = ''; resetSearch(); }
    else openEditor(null);
  });

  function openEditor(product) {
    if (!available || !business || locked() || dialog.open || editorBusy) return;
    if (!discardEditor()) return;
    if (screen !== 'products') navigate('products');
    editing = product;
    $('product-form').reset();
    $('product-form').hidden = false;
    $('product-editor-empty').hidden = true;
    $('product-editor-title').textContent = text(product ? 'editProduct' : 'addProduct');
    for (const key of ['name', 'sku', 'barcode', 'category']) $(`product-${key}`).value = product?.[key] ?? '';
    $('product-unit').value = product?.unit ?? text('defaultUnit');
    $('product-price').value = product?.price ?? '';
    $('product-cost').value = product?.cost ?? 0;
    $('product-track-stock').checked = product ? product.stock_milli !== null : false;
    $('product-stock').value = product?.stock_milli == null ? '0' : decimal(product.stock_milli);
    $('product-archive').hidden = !product;
    notice('product-notice', null);
    editorBaseline = editorValues();
    synchronize();
    $('product-name').focus();
  }
  $('add-product').addEventListener('click', () => openEditor(null));
  for (const id of ['product-close', 'product-cancel']) $(id).addEventListener('click', () => {
    if (!locked() && discardEditor()) $('add-product').focus();
  });
  $('product-track-stock').addEventListener('change', synchronize);

  $('product-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!available || locked() || editorBusy || $('product-form').hidden) return;
    let payload;
    try {
      payload = { id: editing?.id ?? null, revision: editing?.revision ?? null };
      for (const [key, maximum] of [['name', 120], ['sku', 64], ['barcode', 64], ['category', 64], ['unit', 16]]) {
        payload[key] = $(`product-${key}`).value.trim();
        if ((['name', 'unit'].includes(key) && !payload[key]) || encoder.encode(payload[key]).length > maximum) {
          $(`product-${key}`).focus();
          throw new Error('invalid_product');
        }
      }
      payload.price = fixed($('product-price').value, 0);
      payload.cost = fixed($('product-cost').value, 0);
      payload.stock_milli = $('product-track-stock').checked ? fixed($('product-stock').value, 3, limit, 'invalid_product') : null;
    } catch (error) { notice('product-notice', errorCode(error), true); return; }
    editorBusy = true;
    $('product-save').textContent = text('saving');
    notice('product-notice', null);
    synchronize();
    try {
      const result = await request('product.save', payload);
      if (!result?.product) throw new Error('unexpected');
      editing = result.product;
      editorBaseline = editorValues();
      $('product-form').hidden = true;
      $('product-editor-empty').hidden = false;
      resetSearch();
      notice('product-notice', null);
      notice('catalog-notice', 'productSaved');
      if (lines.some((line) => line.product.id === editing.id)) markChanged();
      $('add-product').focus();
    } catch (error) { notice('product-notice', errorCode(error), true); }
    finally { editorBusy = false; $('product-save').textContent = text('saveProduct'); synchronize(); }
  });

  $('product-archive').addEventListener('click', async () => {
    if (!available || !editing || locked() || editorBusy || !window.confirm(text('archiveConfirm', { name: editing.name }))) return;
    editorBusy = true;
    synchronize();
    notice('product-notice', 'saving');
    try {
      const result = await request('product.archive', { id: editing.id, revision: editing.revision });
      if (result?.archived !== true) throw new Error('unexpected');
      if (lines.some((line) => line.product.id === editing.id)) markChanged();
      editing = null;
      $('product-form').hidden = true;
      $('product-editor-empty').hidden = false;
      resetSearch();
      notice('catalog-notice', 'productArchived');
    } catch (error) { notice('product-notice', errorCode(error), true); }
    finally { editorBusy = false; synchronize(); }
  });

  function serializeCart() {
    if (!lines.length || lines.length > 40) throw new Error('invalid_cart');
    const cart = { lines: lines.map((line) => {
      if (line.blocked) throw new Error('productChangedInstruction');
      const quantity = fixed(line.quantity, 3, limit, 'invalidQuantity');
      if (quantity <= 0) throw new Error('invalidQuantity');
      if (encoder.encode(line.note).length > 160) throw new Error('invalidNote');
      return { product_id: line.product.id, revision: line.product.revision, quantity_milli: quantity, discount_kind: line.kind, discount_value: discount(line.kind, line.discount), note: line.note };
    }), discount_kind: $('transaction-discount-kind').value, discount_value: discount($('transaction-discount-kind').value, $('transaction-discount-value').value), cash_rounding_increment: Number($('cash-rounding').value) };
    if (![1, 50, 100].includes(cart.cash_rounding_increment)) throw new Error('invalid_cart');
    return cart;
  }

  function discount(kind, value) {
    if (kind === 'none') return 0;
    if (kind === 'nominal') return fixed(value, 0, limit, 'invalid_discount');
    if (kind === 'percent') return fixed(value, 2, 10000n, 'invalid_discount');
    throw new Error('invalid_discount');
  }

  function quoteStatus(key, error = false) {
    $('quote-notice').textContent = text(key);
    $('quote-notice').classList.toggle('error', error);
    $('quote-notice').setAttribute('role', error ? 'alert' : 'status');
    $('quote-retry').hidden = !error;
    $('quote-retry').textContent = text(key === 'productChangedInstruction' ? 'refreshCatalog' : 'quoteRetry');
  }

  function invalidateQuote(key = 'quoteRequired', error = false) {
    ++quoteSeq;
    clearTimeout(quoteTimer);
    quote = null;
    quoteBusy = false;
    quoteError = error ? key : null;
    renderTotals($('cart-totals'), null);
    for (const element of $('cart-lines').querySelectorAll('[data-line-total]')) element.textContent = text('missingValue');
    quoteStatus(key, error);
    synchronize();
  }

  function markChanged() {
    for (const line of lines) {
      line.blocked = true;
      changedProducts.set(line.product.id, catalogSeq);
    }
    invalidateQuote('productChangedInstruction', true);
    renderCart();
  }

  function scheduleQuote() {
    if (!editableCart()) return;
    invalidateQuote(lines.length ? 'quotePending' : 'quoteRequired');
    if (!lines.length) return;
    try { serializeCart(); }
    catch (error) { invalidateQuote(errorCode(error), true); return; }
    quoteBusy = true;
    synchronize();
    quoteTimer = setTimeout(refreshQuote, 120);
  }

  async function refreshQuote() {
    if (!editableCart() || !lines.length) return;
    clearTimeout(quoteTimer);
    const sequence = ++quoteSeq;
    let cart;
    try { cart = serializeCart(); }
    catch (error) { invalidateQuote(errorCode(error), true); return; }
    quote = null;
    quoteBusy = true;
    quoteError = null;
    renderTotals($('cart-totals'), null);
    quoteStatus('quotePending');
    synchronize();
    try {
      const result = await request('cart.quote', cart);
      if (sequence !== quoteSeq) return;
      if (!validTotals(result?.totals) || !Array.isArray(result.items) || result.items.length !== lines.length) throw new Error('unexpected');
      quote = { cart: freeze(cart), totals: result.totals, items: result.items };
      renderTotals($('cart-totals'), result.totals, true);
      for (let index = 0; index < lines.length; index++) {
        const item = result.items.find((entry) => entry.product_id === lines[index].product.id) ?? result.items[index];
        $(`line-${lines[index].serial}-total`).textContent = money(item.net);
      }
      quoteStatus('quoteReady');
    } catch (error) {
      if (sequence !== quoteSeq) return;
      const code = errorCode(error);
      if (code === 'product_changed' || code === 'product_not_found') { markChanged(); return; }
      quoteError = code;
      quoteStatus(code, true);
    } finally {
      if (sequence === quoteSeq) { quoteBusy = false; synchronize(); }
    }
  }

  $('quote-retry').addEventListener('click', () => {
    if (!editableCart()) return;
    if (lines.some((line) => line.blocked)) loadProducts();
    else refreshQuote();
  });

  function addProduct(product) {
    if (!editableCart() || product.stock_milli === 0) return;
    if (changedProducts.has(product.id) && (catalogLoadedSeq <= changedProducts.get(product.id) || lines.some((line) => line.product.id === product.id))) {
      invalidateQuote('productChangedInstruction', true);
      return;
    }
    const existing = lines.find((line) => line.product.id === product.id);
    if (existing) {
      if (existing.product.revision !== product.revision) { markChanged(); return; }
      try {
        const value = fixed(existing.quantity, 3, limit, 'invalidQuantity');
        if (BigInt(value) + 1000n > limit) throw new Error('invalidQuantity');
        existing.quantity = decimal(value + 1000);
      } catch (error) { invalidateQuote(errorCode(error), true); return; }
    } else {
      if (lines.length >= 40) { quoteStatus('cartLimit', true); return; }
      lines.push({ product: { ...product }, serial: ++lineSerial, quantity: '1', kind: 'none', discount: '0', note: '', blocked: false, optionsOpen: false });
      changedProducts.delete(product.id);
    }
    renderCart();
    scheduleQuote();
  }

  function field(labelKey, element, id) {
    const wrapper = node('div', 'field');
    const label = node('label', '', text(labelKey));
    element.id = id;
    label.htmlFor = id;
    wrapper.append(label, element);
    return wrapper;
  }

  function stepIcon(increase) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(svg.namespaceURI, 'path');
    path.setAttribute('d', increase ? 'M5 12h14M12 5v14' : 'M5 12h14');
    svg.append(path);
    return svg;
  }

  function renderCart() {
    $('cart-lines').replaceChildren();
    $('cart-empty').hidden = lines.length > 0;
    $('transaction-options').hidden = !lines.length;
    $('cart-count').textContent = text('cartCount', { count: lines.length });
    for (const line of lines) {
      const row = node('article', line.blocked ? 'cart-line blocked-line' : 'cart-line');
      row.dataset.lineId = String(line.product.id);
      row.dataset.productId = String(line.product.id);
      const heading = node('div', 'cart-line-heading');
      const name = node('div');
      name.append(node('h3', '', line.product.name), node('p', 'muted', text('receiptQuantity', { quantity: '', unit: line.product.unit, price: money(line.product.price) }).trim()));
      const total = node('strong', 'money', text('missingValue'));
      total.id = `line-${line.serial}-total`;
      total.dataset.lineTotal = String(line.product.id);
      heading.append(name, total);
      row.append(heading);
      if (line.blocked) row.append(node('p', 'line-warning', text('product_changed')));
      const controls = node('div', 'quantity-controls');
      for (const increase of [false, true]) {
        const action = button(increase ? 'increaseQuantity' : 'decreaseQuantity', 'quantity-step plain-button', () => {
          if (!editableCart() || line.blocked) return;
          try {
            const current = fixed(line.quantity, 3, limit, 'invalidQuantity');
            const next = BigInt(current) + (increase ? 1000n : -1000n);
            if (next <= 0n || next > limit) throw new Error('invalidQuantity');
            line.quantity = decimal(Number(next));
            $(`line-${line.serial}-quantity`).value = line.quantity;
            $(`line-${line.serial}-quantity`).removeAttribute('aria-invalid');
            scheduleQuote();
          } catch (error) { invalidateQuote(errorCode(error), true); }
        }, { name: line.product.name });
        action.textContent = '';
        action.append(stepIcon(increase));
        action.setAttribute('aria-label', text(increase ? 'increaseQuantity' : 'decreaseQuantity', { name: line.product.name }));
        action.dataset.action = increase ? 'increase' : 'decrease';
        controls.append(action);
      }
      const quantity = node('input');
      quantity.type = 'text';
      quantity.inputMode = 'decimal';
      quantity.value = line.quantity;
      quantity.id = `line-${line.serial}-quantity`;
      quantity.dataset.action = 'quantity';
      quantity.setAttribute('aria-label', text('quantityNamed', { name: line.product.name }));
      quantity.addEventListener('input', () => {
        if (!editableCart() || line.blocked) return;
        line.quantity = quantity.value;
        try { if (!fixed(quantity.value, 3, limit, 'invalidQuantity')) throw new Error('invalidQuantity'); quantity.removeAttribute('aria-invalid'); }
        catch { quantity.setAttribute('aria-invalid', 'true'); }
        scheduleQuote();
      });
      controls.insertBefore(quantity, controls.lastChild);
      controls.append(node('span', 'quantity-unit', line.product.unit));
      const remove = button('removeLine', 'text-button danger remove-line', () => {
        if (!editableCart()) return;
        const index = lines.indexOf(line);
        lines.splice(index, 1);
        renderCart();
        scheduleQuote();
        const target = lines[Math.min(index, lines.length - 1)];
        (target ? $(`line-${target.serial}-quantity`) : $('product-search')).focus();
      }, { name: line.product.name });
      remove.textContent = text('remove');
      remove.setAttribute('aria-label', text('removeLine', { name: line.product.name }));
      remove.dataset.action = 'remove';
      controls.append(remove);
      row.append(controls);
      const options = node('details', 'line-options');
      options.open = line.optionsOpen;
      options.addEventListener('toggle', () => { line.optionsOpen = options.open; });
      options.append(node('summary', '', text('lineOptions')));
      const discountFields = node('div', 'discount-fields');
      const kind = node('select');
      kind.dataset.action = 'discount-kind';
      for (const [value, key] of [['none', 'discountNone'], ['nominal', 'discountNominal'], ['percent', 'discountPercent']]) {
        const option = node('option', '', text(key));
        option.value = value;
        kind.append(option);
      }
      kind.value = line.kind;
      const value = node('input');
      value.type = 'text';
      value.inputMode = 'decimal';
      value.value = line.discount;
      value.dataset.action = 'discount-value';
      kind.addEventListener('change', () => {
        if (!editableCart() || line.blocked) return;
        line.kind = kind.value;
        line.discount = '0';
        value.value = '0';
        value.disabled = line.kind === 'none';
        scheduleQuote();
      });
      value.addEventListener('input', () => {
        if (!editableCart() || line.blocked) return;
        line.discount = value.value;
        scheduleQuote();
      });
      discountFields.append(field('lineDiscount', kind, `line-${line.serial}-discount-kind`), field('discountValue', value, `line-${line.serial}-discount-value`));
      const noteInput = node('textarea');
      noteInput.rows = 2;
      noteInput.maxLength = 160;
      noteInput.value = line.note;
      noteInput.placeholder = text('notePlaceholder');
      noteInput.dataset.action = 'note';
      noteInput.addEventListener('input', () => {
        if (!editableCart() || line.blocked) return;
        line.note = noteInput.value;
        noteInput.setAttribute('aria-invalid', String(encoder.encode(line.note).length > 160));
        scheduleQuote();
      });
      const noteField = field('note', noteInput, `line-${line.serial}-note`);
      const hint = node('span', 'field-hint', text('noteHint'));
      hint.id = `line-${line.serial}-note-hint`;
      noteInput.setAttribute('aria-describedby', hint.id);
      noteField.append(hint);
      options.append(discountFields, noteField);
      row.append(options);
      for (const control of row.querySelectorAll('input, select, textarea, button')) control.dataset.blocked = String(line.blocked);
      $('cart-lines').append(row);
    }
    synchronize();
    for (const line of lines) $(`line-${line.serial}-discount-value`).disabled = !editableCart() || line.blocked || line.kind === 'none';
  }

  function clearCart() {
    lines = [];
    $('transaction-discount-kind').value = 'none';
    $('transaction-discount-value').value = '0';
    $('cash-rounding').value = '1';
    $('transaction-options').open = false;
    changedProducts.clear();
    invalidateQuote();
    renderCart();
  }
  $('cart-clear').addEventListener('click', () => {
    if (editableCart() && lines.length && window.confirm(text('cartClearConfirm'))) clearCart();
  });
  $('transaction-discount-kind').addEventListener('change', () => {
    if (!editableCart()) return;
    $('transaction-discount-value').value = '0';
    scheduleQuote();
  });
  $('transaction-discount-value').addEventListener('input', scheduleQuote);
  $('cash-rounding').addEventListener('change', scheduleQuote);

  function openPayment() {
    if ($('pay').disabled || !quote || locked() || dialog.open) return;
    resetPrint();
    paymentTotal = quote.totals.total;
    paymentRepair = false;
    paid = false;
    attempt = null;
    $('payment-entry').hidden = false;
    $('payment-success').hidden = true;
    $('payment-total').textContent = money(paymentTotal);
    $('tendered').value = '';
    notice('payment-notice', null);
    dialog.showModal();
    synchronize();
    $('tendered').focus();
  }
  $('pay').addEventListener('click', openPayment);

  function updateTender() {
    if (!dialog.open || paid) return;
    let tendered = null;
    try { tendered = fixed($('tendered').value, 0); }
    catch { tendered = null; }
    const short = tendered !== null && tendered < paymentTotal;
    $('change-label').textContent = text(short ? 'shortfall' : 'change');
    $('payment-change').textContent = tendered === null ? text('missingValue') : money(short ? paymentTotal - tendered : tendered - paymentTotal);
    $('payment-change').classList.toggle('danger', short);
    $('tendered').setAttribute('aria-invalid', String(tendered === null && $('tendered').value !== ''));
    $('payment-submit').disabled = locked() || paymentRepair || tendered === null || short || !quote || quoteBusy;
  }
  $('tendered').addEventListener('input', updateTender);
  for (const quick of document.querySelectorAll('[data-tender]')) quick.addEventListener('click', () => {
    if (locked() || paymentRepair || !dialog.open || paid) return;
    $('tendered').value = quick.dataset.tender === 'exact' ? String(paymentTotal) : quick.dataset.tender;
    updateTender();
    $('tendered').focus();
  });

  function closePayment() {
    if (locked()) return;
    dialog.close();
    resetPrint();
    attempt = null;
    paymentRepair = false;
    paymentTotal = null;
    paid = false;
    synchronize();
    $('product-search').focus();
  }
  $('payment-cancel').addEventListener('click', closePayment);
  $('new-sale').addEventListener('click', closePayment);
  dialog.addEventListener('cancel', (event) => {
    event.preventDefault();
    if (!locked()) closePayment();
  });
  dialog.addEventListener('close', () => {
    if (locked()) { dialog.showModal(); return; }
    synchronize();
  });

  function acknowledgedSale(sale) {
    return sale && ['string', 'number'].includes(typeof sale.id) && ['string', 'number'].includes(typeof sale.number) && typeof sale.business_name === 'string' && Array.isArray(sale.items) && sale.items.length > 0 && validTotals(sale.totals) && Number.isSafeInteger(sale.tendered) && Number.isSafeInteger(sale.change) && sale.tendered === attempt.tendered && sale.totals.total === attempt.expected_total && sale.change === sale.tendered - sale.totals.total;
  }

  function resetPrint() {
    ++printSeq;
    printSale = null;
    printBusy = false;
    notice('print-notice', null);
    $('print-retry').hidden = true;
    $('print-copy').hidden = true;
  }

  // An uncertain original is never resent: it would also kick the drawer and could print twice unmarked.
  async function sendReceipt(copy) {
    if (!available || printSale === null || printBusy) return;
    const sequence = printSeq;
    let retry = false;
    let allowCopy = false;
    printBusy = true;
    $('print-retry').hidden = true;
    $('print-copy').hidden = true;
    notice('print-notice', copy ? 'reprintBusy' : 'receiptPrinting');
    synchronize();
    try {
      const result = await request(copy ? 'receipt.reprint' : 'receipt.print', { id: printSale });
      if (result?.submitted !== true) throw new Error('unexpected');
      if (sequence !== printSeq) return;
      notice('print-notice', copy ? 'reprintSent' : 'receiptPrinted');
      allowCopy = true;
    } catch (error) {
      if (sequence !== printSeq) return;
      const code = errorCode(error);
      if (code === 'invalid_device_config') notice('print-notice', 'receiptNoPrinter', true);
      else if (definitePrintErrors.has(code)) {
        noticeDetail('print-notice', copy ? 'reprintFailed' : 'receiptPrintFailed', code);
        retry = !copy;
        allowCopy = copy;
      } else {
        noticeDetail('print-notice', copy ? 'reprintUnknown' : 'receiptPrintUnknown', code);
        allowCopy = true;
      }
    } finally {
      if (sequence === printSeq) {
        printBusy = false;
        $('print-retry').hidden = !retry;
        $('print-copy').hidden = !allowCopy;
        synchronize();
      }
    }
  }
  $('print-retry').addEventListener('click', () => sendReceipt(false));
  $('print-copy').addEventListener('click', () => sendReceipt(true));

  async function checkout() {
    if (!attempt || checkoutBusy) return;
    const wasUncertain = checkoutUncertain;
    checkoutBusy = true;
    notice('payment-notice', 'paymentBusy');
    synchronize();
    try {
      // Uncertain retries must retain the original key and every byte of its payload.
      const result = await request('sale.checkout', attempt);
      if (!acknowledgedSale(result?.sale)) throw new Error('unexpected');
      renderReceipt($('payment-receipt'), result.sale);
      checkoutUncertain = false;
      checkoutBusy = false;
      paid = true;
      clearCart();
      $('payment-entry').hidden = true;
      $('payment-success').hidden = false;
      notice('payment-notice', null);
      attempt = null;
      synchronize();
      // Print before refreshing the catalog so the receipt request is first in the bridge queue.
      printSale = result.sale.id;
      sendReceipt(false);
      loadProducts();
      $('paid-title').focus();
    } catch (error) {
      const code = errorCode(error);
      checkoutBusy = false;
      if (!wasUncertain && safeCheckoutErrors.has(code)) {
        checkoutUncertain = false;
        attempt = null;
        paymentRepair = true;
        if (code === 'product_changed' || code === 'product_not_found') markChanged();
        else invalidateQuote(code, true);
        notice('payment-notice', 'paymentSafeError', true);
        $('payment-notice').append(node('span', 'error-detail', text(code)));
      } else {
        checkoutUncertain = true;
        notice('payment-notice', 'paymentUnknown', true);
        $('payment-notice').append(node('span', 'error-detail', text(code)));
      }
      synchronize();
      (checkoutUncertain ? $('checkout-retry') : $('payment-cancel')).focus();
    }
  }

  $('payment-form').addEventListener('submit', (event) => {
    event.preventDefault();
    if ($('payment-submit').disabled || locked() || paymentRepair || !quote || !dialog.open) return;
    try {
      const tendered = fixed($('tendered').value, 0);
      if (tendered < quote.totals.total) throw new Error('underpayment');
      attempt = freeze({ checkout_id: crypto.randomUUID(), cart: JSON.parse(JSON.stringify(quote.cart)), tendered, expected_total: quote.totals.total });
      checkout();
    } catch (error) { notice('payment-notice', errorCode(error), true); }
  });
  $('checkout-retry').addEventListener('click', () => { if (checkoutUncertain && attempt && !checkoutBusy) checkout(); });
  window.addEventListener('beforeunload', (event) => {
    if (!locked()) return;
    event.preventDefault();
    event.returnValue = '';
  });

  async function loadHistory() {
    if (locked()) return;
    const sequence = ++historySeq;
    $('sale-list').replaceChildren();
    $('history-empty').hidden = true;
    $('history-retry').hidden = true;
    historyHasMore = false;
    if (!available) { notice('history-notice', 'desktopRequired'); synchronize(); return; }
    if (!business) return;
    historyBusy = true;
    notice('history-notice', 'loadingHistory');
    $('history-content').setAttribute('aria-busy', 'true');
    synchronize();
    try {
      const date = $('history-date').value;
      if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error('invalid_query');
      const result = await request('sale.list', { date, offset: historyOffset });
      if (sequence !== historySeq) return;
      if (!Array.isArray(result?.sales) || typeof result.has_more !== 'boolean') throw new Error('unexpected');
      historyHasMore = result.has_more;
      notice('history-notice', null);
      $('history-empty').hidden = result.sales.length > 0;
      $('history-empty-title').textContent = text(date ? 'noSalesDate' : 'noSales');
      for (const sale of result.sales) {
        const entry = button('viewSale', 'sale-row', () => loadReceipt(sale.id), { number: sale.number });
        entry.textContent = '';
        entry.dataset.saleId = String(sale.id);
        entry.dataset.action = 'view';
        entry.setAttribute('aria-label', text('viewSale', { number: sale.number }));
        entry.setAttribute('aria-pressed', String(selectedSale === sale.id));
        const information = node('span', 'sale-information');
        information.append(node('strong', '', sale.number), node('span', 'muted', dateTime(sale.created_at)));
        const amount = node('span', 'sale-amount');
        amount.append(node('strong', 'money', money(sale.total)), node('span', 'muted', text('saleItems', { count: sale.item_count })));
        entry.append(information, amount);
        $('sale-list').append(entry);
      }
    } catch (error) {
      if (sequence !== historySeq) return;
      notice('history-notice', errorCode(error), true);
      $('history-retry').hidden = false;
    } finally {
      if (sequence === historySeq) {
        historyBusy = false;
        $('history-content').setAttribute('aria-busy', 'false');
        $('history-page').textContent = text('page', { page: Math.floor(historyOffset / 20) + 1 });
        synchronize();
      }
    }
  }

  async function loadReceipt(id) {
    if (!available || locked() || !id) return;
    selectedSale = id;
    const sequence = ++receiptSeq;
    $('history-receipt').replaceChildren();
    $('receipt-placeholder').hidden = true;
    $('receipt-retry').hidden = true;
    $('reprint-bar').hidden = true;
    notice('reprint-notice', null);
    $('history-detail').setAttribute('aria-busy', 'true');
    notice('receipt-notice', 'loadingReceipt');
    for (const row of $('sale-list').querySelectorAll('[data-sale-id]')) row.setAttribute('aria-pressed', String(row.dataset.saleId === String(id)));
    try {
      const result = await request('sale.get', { id });
      if (sequence !== receiptSeq) return;
      if (!result?.sale || !Array.isArray(result.sale.items) || !validTotals(result.sale.totals)) throw new Error('unexpected');
      renderReceipt($('history-receipt'), result.sale);
      notice('receipt-notice', null);
      $('reprint-bar').hidden = false;
    } catch (error) {
      if (sequence !== receiptSeq) return;
      notice('receipt-notice', errorCode(error), true);
      $('receipt-retry').hidden = false;
    } finally { if (sequence === receiptSeq) $('history-detail').setAttribute('aria-busy', 'false'); }
  }

  function resetHistory() {
    if (locked()) return;
    historyOffset = 0;
    selectedSale = null;
    ++receiptSeq;
    $('history-receipt').replaceChildren();
    $('receipt-placeholder').hidden = false;
    notice('receipt-notice', null);
    $('receipt-retry').hidden = true;
    $('reprint-bar').hidden = true;
    loadHistory();
  }
  $('receipt-reprint').addEventListener('click', async () => {
    if (!available || locked() || reprintBusy || selectedSale === null || $('reprint-bar').hidden) return;
    const sequence = receiptSeq;
    reprintBusy = true;
    notice('reprint-notice', 'reprintBusy');
    synchronize();
    try {
      const result = await request('receipt.reprint', { id: selectedSale });
      if (result?.submitted !== true) throw new Error('unexpected');
      if (sequence === receiptSeq) notice('reprint-notice', 'reprintSent');
    } catch (error) {
      if (sequence !== receiptSeq) return;
      const code = errorCode(error);
      if (code === 'invalid_device_config') notice('reprint-notice', 'receiptNoPrinter', true);
      else noticeDetail('reprint-notice', definitePrintErrors.has(code) ? 'reprintFailed' : 'reprintUnknown', code);
    } finally {
      reprintBusy = false;
      synchronize();
    }
  });
  $('history-date').addEventListener('change', resetHistory);
  $('history-all').addEventListener('click', () => { if (!locked()) { $('history-date').value = ''; resetHistory(); } });
  $('history-prev').addEventListener('click', () => { if (!locked() && !historyBusy && historyOffset > 0) { historyOffset -= 20; loadHistory(); } });
  $('history-next').addEventListener('click', () => { if (!locked() && !historyBusy && historyHasMore) { historyOffset += 20; loadHistory(); } });
  $('history-retry').addEventListener('click', loadHistory);
  $('receipt-retry').addEventListener('click', () => loadReceipt(selectedSale));

  document.addEventListener('keydown', (event) => {
    if (event.key === 'F2') {
      event.preventDefault();
      if (locked() || dialog.open || !available || !business) return;
      if (screen !== 'cashier' && screen !== 'products') navigate('cashier');
      if (screen !== 'cashier' && screen !== 'products') return;
      $('product-search').focus();
      $('product-search').select();
    } else if (event.key === 'F8') {
      event.preventDefault();
      if (screen === 'cashier') openPayment();
    } else if (event.key === 'Escape' && !dialog.open && screen === 'products' && !$('product-form').hidden) {
      if (discardEditor()) $('add-product').focus();
    }
  });

  renderCart();
  synchronize();
  if (!available) {
    notice('catalog-notice', 'desktopRequired');
    notice('history-notice', 'desktopRequired');
    quoteStatus('desktopRequired');
  }
  return { setBusiness(value) {
    business = value;
    $('header-business').textContent = value?.name ?? '';
    synchronize();
  } };
}
