import { id as strings } from './strings.js';

const $ = (id) => document.getElementById(id);
const text = (key, values = {}) => (strings[key] ?? strings.unexpected).replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
const currency = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const number = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 });
const money = (value) => Number.isSafeInteger(value) ? currency.format(value) : text('missingValue');
const integer = (value) => Number.isSafeInteger(value) ? number.format(value) : text('missingValue');

function node(tag, className = '', value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (value !== undefined) element.textContent = String(value);
  return element;
}
function decimal(value) {
  if (!Number.isSafeInteger(value)) return text('missingValue');
  const source = String(value).padStart(4, '0');
  const fraction = source.slice(-3).replace(/0+$/, '');
  return source.slice(0, -3) + (fraction ? `,${fraction}` : '');
}
function dateTime(value) {
  if (!value) return text('neverSold');
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? text('missingValue') : new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium' }).format(date);
}
function localDate() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}
function notice(key, error = false) {
  $('report-notice').textContent = key ? text(key) : '';
  $('report-notice').hidden = !key;
  $('report-notice').classList.toggle('error', error);
  $('report-notice').setAttribute('role', error ? 'alert' : 'status');
}
function validNumbers(value, keys) {
  return value && keys.every((key) => Number.isSafeInteger(value[key]));
}
function renderMetrics(id, entries) {
  const container = $(id);
  container.replaceChildren();
  for (const [key, value, monetary = true] of entries) {
    const card = node('article', 'metric-card');
    card.dataset.metric = key;
    card.append(node('span', '', text(key)), node('strong', monetary ? 'money' : '', monetary ? money(value) : integer(value)));
    container.append(card);
  }
}
function emptyRow(table, colspan, key) {
  const row = node('tr');
  const cell = node('td', 'report-empty', text(key));
  cell.colSpan = colspan;
  row.append(cell);
  table.append(row);
}
function cell(row, value, className = '') {
  const element = node('td', className, value);
  row.append(element);
  return element;
}
function validRange(from, to) {
  return /^\d{4}-\d{2}-\d{2}$/.test(from) && /^\d{4}-\d{2}-\d{2}$/.test(to) && from <= to;
}

export function initReports({ request, available }) {
  let view = 'dashboard';
  let busy = false;
  let sequence = 0;
  const pages = {
    sales: { offset: 0, previous: [], hasMore: false },
    profit: { offset: 0, previous: [], hasMore: false },
    stock: { offset: 0, previous: [], hasMore: false },
  };
  $('dashboard-date').value = localDate();
  $('sales-from').value = localDate();
  $('sales-to').value = localDate();
  $('profit-from').value = localDate();
  $('profit-to').value = localDate();

  function synchronize() {
    for (const tab of document.querySelectorAll('[data-report-view]')) {
      const selected = tab.dataset.reportView === view;
      tab.setAttribute('aria-pressed', String(selected));
    }
    for (const name of ['dashboard', 'sales', 'profit', 'stock']) $(`report-${name}`).hidden = name !== view;
    for (const fieldset of document.querySelectorAll('#report-screen fieldset')) fieldset.disabled = !available || busy;
    $('report-refresh').disabled = !available || busy;
    for (const name of ['sales', 'profit', 'stock']) {
      const page = pages[name];
      $(`${name}-prev`).disabled = !available || busy || !page.previous.length;
      $(`${name}-next`).disabled = !available || busy || !page.hasMore;
      $(`${name}-page`).textContent = text('page', { page: page.previous.length + 1 });
    }
  }

  function renderDashboard(result) {
    if (!validNumbers(result, ['sale_count', 'sales_total', 'average_sale', 'revenue', 'cogs', 'gross_profit']) || !Array.isArray(result.hours) || result.hours.length !== 24 || !Array.isArray(result.top_products) || !Array.isArray(result.low_stock)) throw new Error('unexpected');
    renderMetrics('dashboard-metrics', [
      ['saleCount', result.sale_count, false], ['salesTotal', result.sales_total], ['averageSale', result.average_sale],
      ['revenue', result.revenue], ['cogs', result.cogs], ['grossProfit', result.gross_profit],
    ]);
    const hours = $('dashboard-hours');
    hours.replaceChildren();
    const maximum = Math.max(1, ...result.hours.map((bucket) => bucket.sales_total));
    for (const bucket of result.hours) {
      if (!validNumbers(bucket, ['hour', 'sale_count', 'sales_total']) || bucket.hour < 0 || bucket.hour > 23) throw new Error('unexpected');
      const row = node('div', 'hour-row');
      const label = `${String(bucket.hour).padStart(2, '0')}.00`;
      const bar = node('progress');
      bar.max = maximum;
      bar.value = bucket.sales_total;
      bar.setAttribute('aria-label', text('hourSales', { hour: label, count: bucket.sale_count, amount: money(bucket.sales_total) }));
      row.append(node('span', 'hour-label', label), bar, node('span', 'hour-value money', money(bucket.sales_total)));
      hours.append(row);
    }
    const products = $('dashboard-top-products');
    products.replaceChildren();
    if (!result.top_products.length) emptyRow(products, 4, 'noReportSales');
    for (const product of result.top_products) {
      if (!validNumbers(product, ['product_id', 'quantity_milli', 'revenue', 'gross_profit'])) throw new Error('unexpected');
      const row = node('tr');
      cell(row, product.name);
      cell(row, `${decimal(product.quantity_milli)} ${product.unit}`, 'quantity-cell');
      cell(row, money(product.revenue), 'money');
      cell(row, money(product.gross_profit), 'money');
      products.append(row);
    }
    const low = $('dashboard-low-stock');
    low.replaceChildren();
    $('dashboard-low-empty').hidden = result.low_stock.length > 0;
    for (const product of result.low_stock) {
      if (!validNumbers(product, ['product_id', 'stock_milli', 'min_stock_milli'])) throw new Error('unexpected');
      const item = node('li');
      const info = node('div');
      info.append(node('strong', '', product.name), node('span', '', text('minimumStockValue', { quantity: decimal(product.min_stock_milli), unit: product.unit })));
      item.append(info, node('span', 'stock-badge', text('stockValue', { quantity: decimal(product.stock_milli), unit: product.unit })));
      low.append(item);
    }
  }

  function renderSales(result) {
    if (!validNumbers(result, ['sale_count', 'sales_total', 'revenue', 'cogs', 'gross_profit']) || !Array.isArray(result.groups) || typeof result.has_more !== 'boolean') throw new Error('unexpected');
    renderMetrics('sales-metrics', [
      ['saleCount', result.sale_count, false], ['salesTotal', result.sales_total], ['revenue', result.revenue], ['cogs', result.cogs], ['grossProfit', result.gross_profit],
    ]);
    $('sales-group-label').textContent = text({ day: 'date', product: 'product', category: 'category' }[$('sales-group').value]);
    const body = $('sales-groups');
    body.replaceChildren();
    if (!result.groups.length) emptyRow(body, 6, 'noReportSalesRange');
    for (const group of result.groups) {
      if (!validNumbers(group, ['sale_count', 'quantity_milli', 'revenue', 'cogs', 'gross_profit'])) throw new Error('unexpected');
      const row = node('tr');
      cell(row, group.key || text('uncategorized'));
      cell(row, integer(group.sale_count), 'quantity-cell');
      cell(row, group.unit ? `${decimal(group.quantity_milli)} ${group.unit}` : decimal(group.quantity_milli), 'quantity-cell');
      cell(row, money(group.revenue), 'money');
      cell(row, money(group.cogs), 'money');
      cell(row, money(group.gross_profit), 'money');
      body.append(row);
    }
    pages.sales.hasMore = result.has_more;
  }

  function renderProfit(result) {
    if (!validNumbers(result, ['revenue', 'cogs', 'gross_profit', 'expense_total', 'net_profit']) || !Array.isArray(result.expense_categories) || typeof result.has_more !== 'boolean') throw new Error('unexpected');
    renderMetrics('profit-metrics', [
      ['revenue', result.revenue], ['cogs', result.cogs], ['grossProfit', result.gross_profit], ['expenseTotal', result.expense_total], ['netProfit', result.net_profit],
    ]);
    const body = $('profit-categories');
    body.replaceChildren();
    if (!result.expense_categories.length) emptyRow(body, 2, 'noExpenses');
    for (const category of result.expense_categories) {
      if (!validNumbers(category, ['amount'])) throw new Error('unexpected');
      const row = node('tr');
      cell(row, category.category);
      cell(row, money(category.amount), 'money');
      body.append(row);
    }
    pages.profit.hasMore = result.has_more;
  }

  function renderStock(result) {
    if (!validNumbers(result, ['total_products', 'tracked_products', 'low_stock_count', 'dead_stock_count', 'stock_value']) || !Array.isArray(result.products) || typeof result.has_more !== 'boolean') throw new Error('unexpected');
    renderMetrics('stock-metrics', [
      ['totalProducts', result.total_products, false], ['trackedProducts', result.tracked_products, false], ['lowStockCount', result.low_stock_count, false], ['deadStockCount', result.dead_stock_count, false], ['stockValueTotal', result.stock_value],
    ]);
    const body = $('stock-products');
    body.replaceChildren();
    if (!result.products.length) emptyRow(body, 7, 'noStockMatches');
    for (const product of result.products) {
      if (!validNumbers(product, ['product_id', 'cost', 'stock_value']) || !(product.stock_milli === null || Number.isSafeInteger(product.stock_milli))) throw new Error('unexpected');
      const row = node('tr');
      row.dataset.productId = String(product.product_id);
      cell(row, product.name);
      cell(row, product.category || text('uncategorized'));
      cell(row, product.stock_milli === null ? text('untracked') : `${decimal(product.stock_milli)} ${product.unit}`, 'quantity-cell');
      cell(row, product.min_stock_milli === null ? text('missingValue') : `${decimal(product.min_stock_milli)} ${product.unit}`, 'quantity-cell');
      cell(row, product.stock_milli === null ? text('missingValue') : money(product.stock_value), 'money');
      cell(row, dateTime(product.last_sold_at));
      const status = node('td');
      if (product.low_stock) status.append(node('span', 'stock-badge', text(product.stock_milli === 0 ? 'soldOut' : 'lowStock')));
      if (product.dead_stock) status.append(node('span', 'dead-badge', text('deadStock')));
      if (!product.low_stock && !product.dead_stock) status.textContent = text('missingValue');
      row.append(status);
      body.append(row);
    }
    pages.stock.hasMore = result.has_more;
  }

  async function load() {
    if (!available) { notice('desktopRequired', true); synchronize(); return; }
    const ticket = ++sequence;
    busy = true;
    notice('reportLoading');
    synchronize();
    try {
      if (view === 'dashboard') {
        const result = await request('report.dashboard', { date: $('dashboard-date').value });
        if (ticket !== sequence) return;
        renderDashboard(result);
      } else if (view === 'sales') {
        const from = $('sales-from').value;
        const to = $('sales-to').value;
        if (!validRange(from, to)) throw new Error('invalid_query');
        const result = await request('report.sales', { from, to, group_by: $('sales-group').value, offset: pages.sales.offset });
        if (ticket !== sequence) return;
        renderSales(result);
      } else if (view === 'profit') {
        const from = $('profit-from').value;
        const to = $('profit-to').value;
        if (!validRange(from, to)) throw new Error('invalid_query');
        const result = await request('report.profit', { from, to, offset: pages.profit.offset });
        if (ticket !== sequence) return;
        renderProfit(result);
      } else {
        const result = await request('report.stock', { filter: $('stock-filter').value, offset: pages.stock.offset });
        if (ticket !== sequence) return;
        renderStock(result);
      }
      notice(null);
    } catch (error) {
      if (ticket === sequence) notice(error?.message ?? 'unexpected', true);
    } finally {
      if (ticket === sequence) {
        busy = false;
        synchronize();
      }
    }
  }

  function select(next) {
    view = next;
    synchronize();
    load();
  }
  for (const tab of document.querySelectorAll('[data-report-view]')) tab.addEventListener('click', () => select(tab.dataset.reportView));
  $('report-refresh').addEventListener('click', load);
  $('dashboard-form').addEventListener('submit', (event) => { event.preventDefault(); load(); });
  for (const name of ['sales', 'profit', 'stock']) {
    $(`${name}-form`).addEventListener('submit', (event) => {
      event.preventDefault();
      pages[name].offset = 0;
      pages[name].previous = [];
      load();
    });
    $(`${name}-prev`).addEventListener('click', () => {
      if (!pages[name].previous.length) return;
      pages[name].offset = pages[name].previous.pop();
      load();
    });
    $(`${name}-next`).addEventListener('click', () => {
      if (!pages[name].hasMore) return;
      pages[name].previous.push(pages[name].offset);
      pages[name].offset += 50;
      load();
    });
  }
  $('dashboard-stock-action').addEventListener('click', () => {
    $('stock-filter').value = 'low';
    pages.stock.offset = 0;
    pages.stock.previous = [];
    select('stock');
  });
  synchronize();
  return { show: load, refresh: load };
}
