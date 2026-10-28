import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { createServer } from 'node:net';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
await mkdir(path.join(root, '.cache'), { recursive: true });
const data = await mkdtemp(path.join(root, '.cache', 'desktop-test-'));
const runFile = promisify(execFile);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const runtimeErrors = [];

async function rpc(session, command, payload) {
  const response = await session.evaluate(`new Promise((resolve,reject)=>{
    const id=crypto.randomUUID();
    const listener=({data})=>{if(data?.id!==id)return; clearTimeout(timer);chrome.webview.removeEventListener('message',listener);resolve(data);};
    const timer=setTimeout(()=>{chrome.webview.removeEventListener('message',listener);reject(new Error('Bridge test timeout'));},10000);
    chrome.webview.addEventListener('message',listener);
    chrome.webview.postMessage({id,command:${JSON.stringify(command)},payload:${JSON.stringify(payload)}});
  })`);
  return response;
}

async function command(session, name, payload) {
  const response = await rpc(session, name, payload);
  assert.equal(response.ok, true, `${name}: ${JSON.stringify(response)}`);
  return response.result;
}

async function capture(session, width, height) {
  await session.call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
  assert.equal(await session.evaluate('document.documentElement.scrollWidth > innerWidth'), false);
  const screenshot = await session.call('Page.captureScreenshot', { format: 'png' });
  await writeFile(path.join(root, '.cache', `cashier-${width}x${height}.png`), Buffer.from(screenshot.data, 'base64'));
}

async function start() {
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const process = spawn(path.join(root, 'zig-out/bin/KasirKu.exe'), [], {
    env: { ...globalThis.process.env, LOCALAPPDATA: data, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}` },
    stdio: 'ignore',
  });
  let socket;
  try {
    const deadline = Date.now() + 15000;
    let target;
    while (Date.now() < deadline) {
      if (process.exitCode !== null) throw new Error(`Desktop exited: ${process.exitCode}`);
      try {
        const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(500) });
        const targets = await response.json();
        target = targets.find(item => item.url === 'https://kasirku.local/index.html');
        if (target) break;
      } catch {}
      await delay(100);
    }
    assert.ok(target, 'Native WebView2 page did not become available');
    socket = new WebSocket(target.webSocketDebuggerUrl);
    await once(socket, 'open');
    let sequence = 0;
    const pending = new Map();
    socket.addEventListener('message', ({ data }) => {
      const response = JSON.parse(data);
      if (response.method === 'Runtime.exceptionThrown') runtimeErrors.push(response.params.exceptionDetails);
      const entry = pending.get(response.id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(response.id);
      if (response.error) entry.reject(new Error(JSON.stringify(response.error)));
      else entry.resolve(response.result);
    });
    const call = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timeout: ${method}`)); }, 15000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
    const evaluate = async expression => {
      try {
        const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
        if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
        return result.result.value;
      } catch (error) {
        throw new Error(`Evaluating ${expression.slice(0,160)}: ${error.message}`);
      }
    };
    const waitFor = predicate => evaluate(`new Promise((resolve,reject)=>{const check=()=>{if(${predicate}){clearTimeout(timer);observer.disconnect();resolve(true);}};const observer=new MutationObserver(check);const timer=setTimeout(()=>{observer.disconnect();reject(new Error('UI state timeout'));},10000);observer.observe(document.body,{subtree:true,attributes:true,childList:true,characterData:true});check();})`);
    await call('Runtime.enable');
    let ready = false;
    while (Date.now() < deadline) {
      try {
        ready = await evaluate(`document.querySelector('#setup')?.getAttribute('aria-busy')==='false'`);
        if (ready) break;
      } catch (error) {
        if (!/Execution context was destroyed|Cannot find context/.test(error.message)) throw error;
      }
      await delay(100);
    }
    assert.ok(ready, 'Native UI did not finish loading');
    return {
      evaluate, waitFor, call,
      async close() {
        socket.close();
        const exit = once(process, 'exit');
        await runFile('powershell.exe', ['-NoProfile', '-Command', `$p=Get-Process -Id ${process.pid}; if (!$p.CloseMainWindow()) { throw 'Could not close test window' }`]);
        let timer;
        try {
          const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Desktop shutdown timed out')), 15000); });
          const [code] = await Promise.race([exit, timeout]);
          assert.equal(code, 0);
        } finally {
          clearTimeout(timer);
          if (process.exitCode === null) process.kill();
        }
      },
    };
  } catch (error) {
    socket?.close();
    process.kill();
    throw error;
  }
}

let session = await start();
let persistedSale;
let persistedProduct;
let persistedUiSale;
try {
  assert.equal(await session.evaluate(`document.querySelector('#form-fields').disabled`), false);
  await session.evaluate(`document.querySelector('#business-name').value='Toko Uji Desktop'; document.querySelector('#business-address').value='Jalan Uji 27'; document.querySelector('input[value=service]').checked=true; document.querySelector('#business-form').requestSubmit();`);
  await session.waitFor(`document.querySelector('#saved-view').hidden===false`);
  assert.equal(await session.evaluate(`document.querySelector('#saved-name').textContent`), 'Toko Uji Desktop');
  await session.evaluate(`document.querySelector('#check').click();`);
  await session.waitFor(`document.querySelector('#diagnostic-result').textContent.includes('berhasil')`);
  const productInput = { id: null, revision: null, name: 'Beras Pilihan', sku: 'BR-01', barcode: '899000000001', category: 'Sembako', unit: 'kg', price: 15001, cost: 10000, stock_milli: 2000 };
  await session.evaluate(`document.querySelector('#open-cashier').click(); document.querySelector('#add-product').click();`);
  await session.waitFor(`document.querySelector('#product-form').hidden===false`);
  await session.evaluate(`document.querySelector('#product-name').value='Beras Pilihan';document.querySelector('#product-sku').value='BR-01';document.querySelector('#product-barcode').value='899000000001';document.querySelector('#product-category').value='Sembako';document.querySelector('#product-unit').value='kg';document.querySelector('#product-price').value='15001';document.querySelector('#product-cost').value='10000';document.querySelector('#product-track-stock').click();document.querySelector('#product-stock').value='2';document.querySelector('#product-form').requestSubmit();`);
  await session.waitFor(`document.querySelector('#product-fields').disabled===false && document.querySelector('#product-list').textContent.includes('Beras Pilihan')`);
  const product = (await command(session, 'product.list', { query: 'BR-01', offset: 0 })).products[0];
  assert.equal(product.price, 15001);
  assert.equal(product.stock_milli, 2000);
  const lines = [{ product_id: product.id, revision: product.revision, quantity_milli: 500, discount_kind: 'nominal', discount_value: 501, note: 'Setengah kilo' }];
  const cart = { lines, discount_kind: 'percent', discount_value: 1000, cash_rounding_increment: 100 };
  const quote = await command(session, 'cart.quote', cart);
  assert.equal(quote.totals.total, 6300);
  const checkout = { checkout_id: 'desktop-retry-1', cart, tendered: 6000, expected_total: 6300 };
  assert.equal((await rpc(session, 'sale.checkout', checkout)).error.code, 'underpayment');
  assert.equal((await command(session, 'sale.list', { date: '', offset: 0 })).sales.length, 0);
  checkout.tendered = 10000;
  const { sale } = await command(session, 'sale.checkout', checkout);
  persistedSale = sale;
  assert.equal(sale.change, 3700);
  assert.match(sale.number, /^INV-\d{8}-\d{4,}$/);
  assert.equal((await command(session, 'sale.checkout', checkout)).sale.id, sale.id);
  assert.equal((await rpc(session, 'sale.checkout', { ...checkout, tendered: 20000 })).error.code, 'idempotency_conflict');
  const after = (await command(session, 'product.list', { query: 'BR-01', offset: 0 })).products[0];
  assert.equal(after.stock_milli, 1500);
  assert.equal((await rpc(session, 'cart.quote', cart)).error.code, 'product_changed');
  const tooMany = { ...cart, lines: [{ ...lines[0], revision: after.revision, quantity_milli: 2000 }] };
  assert.equal((await rpc(session, 'cart.quote', tooMany)).error.code, 'insufficient_stock');
  const edited = await command(session, 'product.save', { ...productInput, id: after.id, revision: after.revision, name: 'Nama baru', price: 25000, stock_milli: after.stock_milli });
  persistedProduct = edited.product;
  assert.equal((await command(session, 'sale.get', { id: sale.id })).sale.items[0].name, 'Beras Pilihan');
  assert.equal((await command(session, 'sale.get', { id: sale.id })).sale.items[0].unit_price, 15001);
  await command(session, 'product.archive', { id: persistedProduct.id, revision: persistedProduct.revision });
  assert.equal((await command(session, 'product.list', { query: 'BR-01', offset: 0 })).products.length, 0);
  assert.equal((await command(session, 'sale.checkout', checkout)).sale.id, sale.id);
  await session.evaluate(`document.querySelector('#add-product').click();`);
  await session.waitFor(`document.querySelector('#product-form').hidden===false`);
  await session.evaluate(`document.querySelector('#product-name').value='Kopi susu';document.querySelector('#product-sku').value='COFFEE-UI';document.querySelector('#product-unit').value='gelas';document.querySelector('#product-price').value='9900';document.querySelector('#product-cost').value='5000';if(document.querySelector('#product-track-stock').checked)document.querySelector('#product-track-stock').click();document.querySelector('#product-form').requestSubmit();`);
  await session.waitFor(`document.querySelector('#product-list').textContent.includes('Kopi susu') && document.querySelector('#product-fields').disabled===false`);
  await session.evaluate(`document.querySelector('[data-nav="cashier"]').click();`);
  await session.waitFor(`document.querySelector('#product-list button')!==null`);
  await session.evaluate(`document.querySelector('#product-list button[data-action="add"]').click();`);
  await session.waitFor(`document.querySelector('#pay').disabled===false`);
  await session.evaluate(`const quantity=document.querySelector('#cart-lines input[inputmode="decimal"]');quantity.value='0,5';quantity.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#transaction-options').open=true;document.querySelector('#transaction-discount-kind').value='percent';document.querySelector('#transaction-discount-kind').dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('#transaction-discount-value').value='10';document.querySelector('#transaction-discount-value').dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#cash-rounding').value='100';document.querySelector('#cash-rounding').dispatchEvent(new Event('change',{bubbles:true}));`);
  await session.waitFor(`document.querySelector('#pay').disabled===false`);
  for (const [width,height] of [[1366,768],[1000,640]]) {
    await capture(session,width,height);
    assert.ok(await session.evaluate(`(()=>{const r=document.querySelector('#pay').getBoundingClientRect();return r.height>=44&&r.bottom<=innerHeight;})()`));
  }
  await session.evaluate(`document.querySelector('#pay').click();document.querySelector('#tendered').value='10000';document.querySelector('#tendered').dispatchEvent(new Event('input',{bubbles:true}));`);
  await session.waitFor(`document.querySelector('#payment-submit').disabled===false`);
  assert.ok(await session.evaluate(`(()=>{const r=document.querySelector('#payment-submit').getBoundingClientRect();return r.bottom<=innerHeight;})()`));
  const paymentScreenshot = await session.call('Page.captureScreenshot',{format:'png'});
  await writeFile(path.join(root,'.cache','payment-native.png'),Buffer.from(paymentScreenshot.data,'base64'));
  await session.evaluate(`document.querySelector('#payment-form').requestSubmit();`);
  await session.waitFor(`document.querySelector('#payment-success').hidden===false`);
  assert.match(await session.evaluate(`document.querySelector('#payment-receipt .receipt-item-heading').textContent`), /4\.950/);
  const receiptScreenshot = await session.call('Page.captureScreenshot',{format:'png'});
  await writeFile(path.join(root,'.cache','receipt-native.png'),Buffer.from(receiptScreenshot.data,'base64'));
  const uiSummary = (await command(session,'sale.list',{date:'',offset:0})).sales[0];
  persistedUiSale = (await command(session,'sale.get',{id:uiSummary.id})).sale;
  assert.equal(persistedUiSale.items[0].name,'Kopi susu');
  assert.equal(persistedUiSale.items[0].quantity_milli,500);
  assert.equal(persistedUiSale.totals.total,4500);
  assert.equal(persistedUiSale.change,5500);
  await session.evaluate(`document.querySelector('#new-sale').click();document.querySelector('[data-nav="history"]').click();`);
  await session.waitFor(`document.querySelector('#sale-list button')!==null`);
  await session.evaluate(`document.querySelector('#sale-list button').click();`);
  await session.waitFor(`document.querySelector('#history-receipt').textContent.includes('Kopi susu')`);
  await session.call('Page.navigate', { url: 'https://blocked.invalid/' });
  assert.equal(await session.evaluate('location.href'), 'https://kasirku.local/index.html');
} finally { await session.close(); }
const db = new DatabaseSync(path.join(data, 'KasirKu/kasirku.db'), { readOnly: true });
assert.equal(db.prepare('SELECT name FROM business').get().name, 'Toko Uji Desktop');
assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
assert.equal(db.prepare('PRAGMA journal_mode').get().journal_mode, 'wal');
db.close();
session = await start();
try {
  assert.equal(await session.evaluate(`document.querySelector('#saved-view').hidden`), false);
  assert.equal(await session.evaluate(`document.querySelector('#saved-name').textContent`), 'Toko Uji Desktop');
  assert.equal(await session.evaluate(`document.querySelector('#saved-mode').textContent`), 'Jasa');
  const history = await command(session, 'sale.list', { date: '', offset: 0 });
  assert.equal(history.sales.length, 2);
  assert.equal(history.sales[0].id, persistedUiSale.id);
  assert.equal(history.sales[1].id, persistedSale.id);
  const detail = (await command(session, 'sale.get', { id: persistedSale.id })).sale;
  assert.equal(detail.items[0].name, 'Beras Pilihan');
  assert.equal(detail.items[0].quantity_milli, 500);
  assert.equal(detail.totals.total, 6300);
  assert.equal((await command(session, 'product.list', { query: 'BR-01', offset: 0 })).products.length, 0);
} finally { await session.close(); }
assert.deepEqual(runtimeErrors, []);
console.log('Native desktop tests passed: real WebView2/Zig/SQLite product CRUD, fractional quote, discounts, cash, stock, idempotent retry, immutable history, blocked navigation, clean shutdown and restart persistence.');
console.log(`Isolated test data: ${data}`);
