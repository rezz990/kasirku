import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const cache = path.join(root, '.cache');
await mkdir(cache, { recursive: true });
const browserPath = process.env.KASIRKU_BROWSER ?? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = spawn(browserPath, ['--headless', '--disable-gpu', '--no-first-run', '--disable-background-networking', '--remote-debugging-pipe', `--user-data-dir=${path.join(cache, 'ui-test-profile')}`], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let sequence = 0;
let buffer = '';
const pending = new Map();
const listeners = new Set();
const errors = [];
let stderr = '';
browser.stderr.on('data', data => { stderr = (stderr + data).slice(-8000); });
browser.stdio[4].on('data', data => {
  buffer += data.toString();
  let boundary;
  while ((boundary = buffer.indexOf('\0')) !== -1) {
    const value = JSON.parse(buffer.slice(0, boundary));
    buffer = buffer.slice(boundary + 1);
    if (value.id) {
      const entry = pending.get(value.id);
      if (entry) {
        clearTimeout(entry.timer);
        pending.delete(value.id);
        if (value.error) entry.reject(new Error(JSON.stringify(value.error)));
        else entry.resolve(value.result);
      }
    } else {
      if (value.method === 'Runtime.exceptionThrown') errors.push(value.params.exceptionDetails);
      for (const listener of listeners) listener(value);
    }
  }
});
function send(method, params = {}, sessionId) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out: ${method}\n${stderr}`)); }, 15000);
    pending.set(id, { resolve, reject, timer });
    browser.stdio[3].write(`${JSON.stringify({ id, method, params, sessionId })}\0`);
  });
}
function event(method, sessionId) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { listeners.delete(listener); reject(new Error(`Timed out: ${method}`)); }, 15000);
    const listener = value => {
      if (value.method === method && value.sessionId === sessionId) {
        clearTimeout(timer);
        listeners.delete(listener);
        resolve(value.params);
      }
    };
    listeners.add(listener);
  });
}
const mock = `(() => {
  const listeners = []; let business = null;
  const products = window.__products = []; const sales = window.__sales = [];
  window.__requests = []; window.__failNext = false; window.__rejectQuote = null;
  window.__deferPing = false; window.__pendingPing = null;
  window.__deferSave = false; window.__pendingSave = null;
  window.__deferQuote = false; window.__pendingQuotes = [];
  window.__dropCheckoutAck = false; window.__unknownCheckoutAck = false;
  window.__checkoutErrorOnce = null;
  window.__quoteTotal = 9900;
  window.__deviceConfig = {printer_kind:'spooler',printer_name:'',file_path:'',tcp_host:'',tcp_port:9100,paper_width:80,header:'',footer:'',qr_payload:'',copies:1,feed_lines:3,show_sku:false,show_barcode:false,show_qr:false,cash_drawer:true,cut_paper:true};
  window.__logo = null; window.__printError = null;
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    addEventListener(type, callback) { if (type === 'message') listeners.push(callback); },
    postMessage(message) {
      window.__requests.push(message); let result, error;
      if (message.command === 'app.status') result = { business, version: '0.1.0' };
      else if (message.command === 'system.ping') result = { pong: true };
      else if (message.command === 'product.list') result = { products: products.filter(p=>!p.archived && [p.name,p.sku,p.barcode,p.category].some(v=>v.includes(message.payload.query))), has_more: false };
      else if (message.command === 'product.save') {
        const previous = products.find(p=>p.id===message.payload.id);
        const product = { ...message.payload, id: previous?.id ?? products.length+1, revision: (previous?.revision ?? 0)+1 };
        if(previous) Object.assign(previous, product); else products.push(product);
        result = { product };
      }
      else if (message.command === 'product.archive') { products.find(p=>p.id===message.payload.id).archived=true; result={archived:true}; }
      else if (message.command === 'sale.checkout' && window.__checkoutErrorOnce) { error={code:window.__checkoutErrorOnce};window.__checkoutErrorOnce=null; }
      else if (message.command === 'cart.quote' || message.command === 'sale.checkout') {
        const cart=message.command==='cart.quote'?message.payload:message.payload.cart;
        const items=cart.lines.map(line=>{
          const p=products.find(p=>p.id===line.product_id);
          return {...line,name:p.name,sku:p.sku,unit:p.unit,unit_price:p.price,unit_cost:p.cost,gross:window.__quoteTotal,discount:0,net:window.__quoteTotal};
        });
        const totals={gross:window.__quoteTotal,line_discount:0,subtotal:window.__quoteTotal,transaction_discount:0,net_subtotal:window.__quoteTotal,service_charge:0,tax_base:window.__quoteTotal,tax:0,total_before_rounding:window.__quoteTotal,rounding_adjustment:0,total:window.__quoteTotal};
        if(message.command==='cart.quote') {
          if(window.__rejectQuote) error={code:window.__rejectQuote};
          else result={items,totals};
        }
        else {
          let sale=sales.find(s=>s.checkout_id===message.payload.checkout_id);
          if(!sale){sale={id:sales.length+1,checkout_id:message.payload.checkout_id,number:'INV-20261027-0001',created_at:'2026-10-27T10:00:00Z',business_name:business.name,business_address:business.address,items,totals,tendered:message.payload.tendered,change:message.payload.tendered-window.__quoteTotal};sales.push(sale);}
          result={sale};
          if (window.__unknownCheckoutAck) { window.__unknownCheckoutAck=false; result=undefined; error={code:'checkout_unknown'}; }
        }
      }
      else if (message.command === 'sale.list') result = { sales: sales.map(s=>({id:s.id,number:s.number,created_at:s.created_at,total:s.totals.total,tendered:s.tendered,change:s.change,item_count:s.items.length})), has_more: false };
      else if (message.command === 'sale.get') result={sale:sales.find(s=>s.id===message.payload.id)};
      else if (message.command === 'business.save') {
        if (window.__failNext) { window.__failNext = false; error = { code: 'disk_full' }; }
        else { business = message.payload; result = { saved: true }; }
      }
      else if (message.command === 'device.get') result = { config: { ...window.__deviceConfig }, logo: window.__logo };
      else if (message.command === 'device.save') { window.__deviceConfig = { ...message.payload }; result = { saved: true }; }
      else if (message.command === 'device.preview') {
        const c = message.payload;
        result = { text: [...(window.__logo ? ['[logo]'] : []), business.name, c.header, '-'.repeat(c.paper_width === 58 ? 32 : 48), 'TOTAL 9.900', c.footer].join('\\n') + '\\n', width: c.paper_width };
      }
      else if (message.command === 'device.printers') result = { printers: [{ name: 'Microsoft Print to PDF', is_default: false }, { name: 'POS-80', is_default: true }] };
      else if (message.command === 'device.logo_save') { window.__logo = { ...message.payload }; result = { saved: true }; }
      else if (message.command === 'device.logo_clear') { window.__logo = null; result = { saved: true }; }
      else if (message.command === 'device.test_print' || message.command === 'device.open_drawer') result = { submitted: true };
      else if (message.command === 'receipt.print' || message.command === 'receipt.reprint') {
        const c = window.__deviceConfig;
        if (!c.printer_name && !c.tcp_host && !c.file_path) error = { code: 'invalid_device_config' };
        else if (window.__printError) { error = { code: window.__printError }; window.__printError = null; }
        else result = { submitted: true, is_copy: message.command === 'receipt.reprint' };
      } else error = { code: 'unknown_command' };
      const deliver = () => listeners.forEach(callback => callback({ data: { id: message.id, ok: !error, result, error } }));
      if (message.command === 'system.ping' && window.__deferPing) window.__pendingPing = deliver;
      else if (message.command === 'business.save' && window.__deferSave) window.__pendingSave = deliver;
      else if (message.command === 'cart.quote' && window.__deferQuote) window.__pendingQuotes.push(deliver);
      else if (message.command === 'sale.checkout' && window.__dropCheckoutAck) window.__dropCheckoutAck=false;
      else queueMicrotask(deliver);
    }
  };
})();`;

try {
  await send('Browser.getVersion');
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const call = (method, params) => send(method, params, sessionId);
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const waitFor = predicate => evaluate(`new Promise((resolve,reject)=>{const check=()=>{if(${predicate}){clearTimeout(timer);observer.disconnect();resolve(true);}};const observer=new MutationObserver(check);const timer=setTimeout(()=>{observer.disconnect();reject(new Error('UI state timeout: '+${JSON.stringify(predicate)}));},12000);observer.observe(document.body,{subtree:true,attributes:true,childList:true,characterData:true});check();})`);
  await call('Page.enable');
  await call('Runtime.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 1366, height: 768, deviceScaleFactor: 1, mobile: false });
  async function navigate() {
    const loaded = event('Page.loadEventFired', sessionId);
    await call('Page.navigate', { url: 'http://127.0.0.1:4173' });
    await loaded;
  }
  await navigate();
  await waitFor(`document.querySelector('#setup').getAttribute('aria-busy')==='false'`);
  assert.equal(await evaluate('document.querySelector("#form-fields").disabled'), true);
  assert.match(await evaluate('document.querySelector("#notice").textContent'), /pratinjau/);
  assert.equal(await evaluate(`document.querySelector('[data-nav="cashier"]').disabled`), true);
  await call('Page.addScriptToEvaluateOnNewDocument', { source: mock });
  await navigate();
  await waitFor(`document.querySelector('#setup').getAttribute('aria-busy')==='false'`);
  assert.equal(await evaluate('document.querySelector("#form-fields").disabled'), false);
  await evaluate(`window.__deferPing=true; window.__deferSave=true; document.querySelector('#check').click();`);
  await evaluate(`document.querySelector('#business-name').value='Toko Sinar Pagi'; document.querySelector('#business-address').value='Jalan Mawar 12'; document.querySelector('input[value=food]').checked=true; document.querySelector('#business-form').requestSubmit();`);
  await evaluate(`window.__pendingPing(); window.__deferPing=false;`);
  assert.equal(await evaluate(`window.__requests.filter(request=>request.command==='app.status').length`), 1);
  await evaluate(`window.__pendingSave(); window.__deferSave=false;`);
  assert.equal(await evaluate('document.querySelector("#saved-view").hidden'), false);
  assert.equal(await evaluate('document.querySelector("#saved-name").textContent'), 'Toko Sinar Pagi');
  assert.equal(await evaluate('document.querySelector("#saved-mode").textContent'), 'Makan & minum');
  await evaluate(`document.querySelector('#edit').click(); window.__failNext=true; document.querySelector('#business-name').value='Belum tersimpan'; document.querySelector('#business-form').requestSubmit();`);
  assert.equal(await evaluate('document.querySelector("#business-form").hidden'), false);
  assert.equal(await evaluate('document.querySelector("#business-name").value'), 'Belum tersimpan');
  assert.match(await evaluate('document.querySelector("#notice").textContent'), /penuh/);
  assert.equal(await evaluate('document.querySelector("#form-fields").disabled'), false);
  await evaluate(`document.querySelector('#business-name').value='   '; document.querySelector('#business-form').requestSubmit();`);
  assert.match(await evaluate('document.querySelector("#notice").textContent'), /wajib/);
  await evaluate(`document.querySelector('#business-name').value='<img src=x onerror=alert(1)>'; document.querySelector('#business-form').requestSubmit();`);
  assert.equal(await evaluate('document.querySelector("#saved-name").children.length'), 0);
  assert.equal(await evaluate('document.querySelector("#saved-name").textContent'), '<img src=x onerror=alert(1)>');
  await evaluate(`document.querySelector('#check').click();`);
  assert.match(await evaluate('document.querySelector("#diagnostic-result").textContent'), /berhasil/);
  await evaluate(`document.querySelector('#edit').click(); document.querySelector('#business-name').value='Toko Sinar Pagi';`);
  for (const [width, height] of [[1366, 768], [1000, 640]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
    const saveBounds = await evaluate(`(() => { const r=document.querySelector('#save').getBoundingClientRect();return {bottom:r.bottom,height:innerHeight};})()`);
    assert.ok(saveBounds.bottom <= saveBounds.height, `Save button outside viewport at ${width}x${height}`);
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(path.join(cache, `ui-${width}x${height}.png`), Buffer.from(screenshot.data, 'base64'));
  }
  await evaluate(`document.querySelector('#business-form').requestSubmit();`);
  await waitFor(`document.querySelector('#saved-view').hidden===false`);
  await evaluate(`document.querySelector('#open-cashier').click(); document.querySelector('#add-product').click();`);
  await waitFor(`document.querySelector('#product-form').hidden===false`);
  await evaluate(`document.querySelector('#product-name').value='<img src=x onerror=alert(1)>';document.querySelector('#product-sku').value='UI-01';document.querySelector('#product-unit').value='kg';document.querySelector('#product-price').value='-1';document.querySelector('#product-cost').value='5000';document.querySelector('#product-track-stock').click();document.querySelector('#product-stock').value='2,5';document.querySelector('#product-form').requestSubmit();`);
  await waitFor(`document.querySelector('#product-notice').hidden===false`);
  assert.equal(await evaluate(`window.__products.length`), 0);
  await evaluate(`document.querySelector('#product-price').value='9900';document.querySelector('#product-form').requestSubmit();`);
  await waitFor(`window.__products.length===1 && document.querySelector('#product-fields').disabled===false`);
  assert.equal(await evaluate(`window.__products[0].stock_milli`), 2500);
  await evaluate(`document.querySelector('[data-nav="cashier"]').click();`);
  await waitFor(`document.querySelector('#product-list button')!==null`);
  assert.equal(await evaluate(`document.querySelector('#product-list img')!==null`), false);
  await call('Input.dispatchKeyEvent', { type:'keyDown', key:'F2', code:'F2', windowsVirtualKeyCode:113 });
  await call('Input.dispatchKeyEvent', { type:'keyUp', key:'F2', code:'F2', windowsVirtualKeyCode:113 });
  assert.equal(await evaluate(`document.activeElement.id`), 'product-search');
  const addCart = async () => {
    await evaluate(`document.querySelector('#product-list button[data-action="add"]').click();`);
    await waitFor(`document.querySelector('#pay').disabled===false`);
  };
  const quantity = `document.querySelector('#cart-lines input[inputmode="decimal"]')`;
  await addCart();
  await evaluate(`${quantity}.value='0,0001';${quantity}.dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`document.querySelector('#pay').disabled===true`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='cart.quote').at(-1).payload.lines[0].quantity_milli`), 1000);
  await evaluate(`${quantity}.value='0,5';${quantity}.dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`document.querySelector('#pay').disabled===false`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='cart.quote').at(-1).payload.lines[0].quantity_milli`), 500);
  await evaluate(`document.querySelector('#transaction-options').open=true;document.querySelector('#transaction-discount-kind').value='percent';document.querySelector('#transaction-discount-kind').dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('#transaction-discount-value').value='12,5';document.querySelector('#transaction-discount-value').dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`document.querySelector('#pay').disabled===false`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='cart.quote').at(-1).payload.discount_value`), 1250);
  await evaluate(`window.__deferQuote=true;window.__quoteTotal=1111;${quantity}.value='0,6';${quantity}.dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`window.__pendingQuotes.length===1`);
  await evaluate(`window.__quoteTotal=9900;${quantity}.value='0,7';${quantity}.dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`window.__pendingQuotes.length===2`);
  assert.equal(await evaluate(`document.querySelector('#pay').disabled`), true);
  await evaluate(`window.__pendingQuotes[1]();`);
  await waitFor(`document.querySelector('#pay').disabled===false`);
  const latestTotal = await evaluate(`document.querySelector('#cart-totals').textContent`);
  await evaluate(`window.__pendingQuotes[0]();window.__deferQuote=false;`);
  assert.equal(await evaluate(`document.querySelector('#cart-totals').textContent`), latestTotal);
  for (const [width, height] of [[1366,768],[1000,640]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
    assert.ok(await evaluate(`(()=>{const r=document.querySelector('#pay').getBoundingClientRect();return r.height>=44&&r.bottom<=innerHeight;})()`));
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(path.join(cache, `pos-ui-${width}x${height}.png`), Buffer.from(screenshot.data,'base64'));
  }
  await evaluate(`document.querySelector('#pay').click();document.querySelector('#tendered').value='9800';document.querySelector('#tendered').dispatchEvent(new Event('input',{bubbles:true}));`);
  assert.equal(await evaluate(`document.querySelector('#payment-submit').disabled`), true);
  assert.equal(await evaluate(`window.__requests.some(r=>r.command==='sale.checkout')`), false);
  await evaluate(`window.__unknownCheckoutAck=true;document.querySelector('#tendered').value='10000';document.querySelector('#tendered').dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#payment-form').requestSubmit();`);
  await waitFor(`document.querySelector('#checkout-retry').hidden===false`);
  assert.equal(await evaluate(`document.querySelector('#payment-cancel').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#tendered').matches(':disabled')`), true);
  assert.equal(await evaluate(`window.__sales.length`), 1);
  await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  assert.equal(await evaluate(`document.querySelector('#payment-dialog').open`), true);
  await evaluate(`window.__checkoutErrorOnce='database_busy';document.querySelector('#checkout-retry').click();`);
  await waitFor(`document.querySelector('#checkout-retry').hidden===false && document.querySelector('#checkout-retry').disabled===false`);
  assert.equal(await evaluate(`document.querySelector('#payment-cancel').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#tendered').matches(':disabled')`), true);
  await evaluate(`document.querySelector('#checkout-retry').click();`);
  await waitFor(`document.querySelector('#payment-success').hidden===false`);
  let attempts = await evaluate(`window.__requests.filter(r=>r.command==='sale.checkout').map(r=>r.payload)`);
  assert.deepEqual(attempts[0], attempts[1]);
  assert.deepEqual(attempts[0], attempts[2]);
  assert.equal(await evaluate(`window.__sales.length`), 1);
  assert.equal(await evaluate(`document.querySelector('#payment-receipt img')!==null`), false);
  await waitFor(`document.querySelector('#print-notice').textContent.includes('belum diatur')`);
  assert.equal(await evaluate(`document.querySelector('#print-retry').hidden && document.querySelector('#print-copy').hidden`), true);
  await evaluate(`document.querySelector('#new-sale').click();`);
  await addCart();
  await evaluate(`window.__dropCheckoutAck=true;document.querySelector('#pay').click();document.querySelector('[data-tender="exact"]').click();document.querySelector('#payment-form').requestSubmit();`);
  await waitFor(`document.querySelector('#checkout-retry').hidden===false`);
  await evaluate(`document.querySelector('#checkout-retry').click();`);
  await waitFor(`document.querySelector('#payment-success').hidden===false`);
  attempts = await evaluate(`window.__requests.filter(r=>r.command==='sale.checkout').map(r=>r.payload)`);
  assert.deepEqual(attempts[3], attempts[4]);
  assert.notEqual(attempts[0].checkout_id, attempts[3].checkout_id);
  assert.equal(await evaluate(`window.__sales.length`), 2);
  await evaluate(`document.querySelector('#new-sale').click();document.querySelector('[data-nav="device"]').click();`);
  await waitFor(`document.querySelector('#device-fields').disabled===false && document.querySelector('#device-paper pre')!==null`);
  assert.equal(await evaluate(`document.querySelector('#device-test-print').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#device-save').disabled`), true);
  await evaluate(`document.querySelector('#device-detect').click();`);
  await waitFor(`document.querySelector('#device-printer-name').value==='POS-80' && document.querySelector('#device-save').disabled===false`);
  assert.equal(await evaluate(`document.querySelector('#device-test-print').disabled`), true);
  await evaluate(`const h=document.querySelector('#device-header');h.value='<b>Promo</b>';h.dispatchEvent(new Event('input',{bubbles:true}));const w=document.querySelector('input[name="paper_width"][value="58"]');w.checked=true;w.dispatchEvent(new Event('change',{bubbles:true}));`);
  await waitFor(`document.querySelector('#device-paper').dataset.width==='58' && document.querySelector('#device-paper').textContent.includes('<b>Promo</b>')`);
  assert.equal(await evaluate(`document.querySelector('#device-paper b')!==null`), false);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='device.preview').at(-1).payload.paper_width`), 58);
  await evaluate(`window.confirm=()=>false;document.querySelector('[data-nav="cashier"]').click();`);
  assert.equal(await evaluate(`document.querySelector('#device-screen').hidden`), false);
  for (const [width, height] of [[1366,768],[1000,640]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
    assert.ok(await evaluate(`(()=>{const r=document.querySelector('#device-save').getBoundingClientRect();return r.height>=44&&r.bottom<=innerHeight;})()`), `Device save outside viewport at ${width}x${height}`);
    assert.ok(await evaluate(`document.querySelector('.paper-frame').scrollWidth<=document.querySelector('.paper-frame').clientWidth`), `Receipt preview overflows at ${width}x${height}`);
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(path.join(cache, `device-ui-${width}x${height}.png`), Buffer.from(screenshot.data,'base64'));
  }
  await evaluate(`document.querySelector('#device-form').requestSubmit();`);
  await waitFor(`document.querySelector('#device-test-print').disabled===false`);
  assert.deepEqual(await evaluate(`[window.__deviceConfig.printer_name, window.__deviceConfig.paper_width, window.__deviceConfig.header]`), ['POS-80', 58, '<b>Promo</b>']);
  await evaluate(`document.querySelector('#device-test-print').click();`);
  await waitFor(`document.querySelector('#device-test-notice').hidden===false && document.querySelector('#device-test-print').disabled===false`);
  assert.equal(await evaluate(`window.__requests.some(r=>r.command==='device.test_print')`), true);
  await evaluate(`(async()=>{const c=new OffscreenCanvas(600,200);const x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,600,200);x.fillStyle='#000';x.fillRect(50,50,500,100);const blob=await c.convertToBlob({type:'image/png'});const t=new DataTransfer();t.items.add(new File([blob],'logo.png',{type:'image/png'}));const input=document.querySelector('#device-logo-file');input.files=t.files;input.dispatchEvent(new Event('change',{bubbles:true}));})()`);
  await waitFor(`document.querySelector('#device-paper canvas')!==null`);
  assert.deepEqual(await evaluate(`[window.__logo.width, window.__logo.height, atob(window.__logo.bits_base64).length]`), [384, 128, 48 * 128]);
  assert.equal(await evaluate(`document.querySelector('#device-paper').textContent.includes('[logo]')`), false);
  await evaluate(`const s=document.querySelector('#scanner-input');s.value='UI-01';document.querySelector('#scanner-form').requestSubmit();`);
  await waitFor(`document.querySelector('#scanner-result .scan-match')!==null`);
  assert.equal(await evaluate(`document.querySelector('#scanner-result img')!==null`), false);
  await evaluate(`document.querySelector('[data-nav="history"]').click();`);
  await waitFor(`document.querySelector('#sale-list button')!==null`);
  await evaluate(`document.querySelector('#sale-list button').click();`);
  await waitFor(`document.querySelector('#reprint-bar').hidden===false`);
  await evaluate(`document.querySelector('#receipt-reprint').click();`);
  await waitFor(`document.querySelector('#reprint-notice').textContent.includes('SALINAN')`);
  await evaluate(`window.__printError='print_unknown';document.querySelector('#receipt-reprint').click();`);
  await waitFor(`document.querySelector('#reprint-notice').textContent.includes('mungkin')`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='receipt.reprint').length`), 2);
  await evaluate(`document.querySelector('[data-nav="cashier"]').click();`);
  await waitFor(`document.querySelector('#product-list button[data-action="add"]')!==null`);
  await addCart();
  await evaluate(`window.__printError='printer_unreachable';document.querySelector('#pay').click();document.querySelector('[data-tender="exact"]').click();document.querySelector('#payment-form').requestSubmit();`);
  await waitFor(`document.querySelector('#print-retry').hidden===false`);
  assert.equal(await evaluate(`document.querySelector('#print-copy').hidden`), true);
  const afterCheckout = await evaluate(`(()=>{const i=window.__requests.findLastIndex(r=>r.command==='sale.checkout');return window.__requests.slice(i+1).map(r=>r.command);})()`);
  assert.ok(afterCheckout.indexOf('receipt.print') === 0, `Receipt print was not first after checkout: ${afterCheckout}`);
  await evaluate(`document.querySelector('#print-retry').click();`);
  await waitFor(`document.querySelector('#print-notice').textContent.includes('terkirim') && document.querySelector('#print-copy').hidden===false`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='receipt.print').at(-1).payload.id`), 3);
  await evaluate(`window.__printError='print_unknown';document.querySelector('#print-copy').click();`);
  await waitFor(`document.querySelector('#print-notice').textContent.includes('mungkin') && document.querySelector('#print-copy').hidden===false`);
  assert.equal(await evaluate(`document.querySelector('#print-retry').hidden`), true);
  await evaluate(`document.querySelector('#new-sale').click();document.querySelector('[data-nav="history"]').click();`);
  await waitFor(`document.querySelector('#sale-list button')!==null`);
  await evaluate(`document.querySelector('#sale-list button').click();`);
  await waitFor(`document.querySelector('#history-receipt').textContent.includes('INV-')`);
  assert.equal(await evaluate(`document.querySelector('#history-receipt img')!==null`), false);
  await evaluate(`window.__quoteTotal=9000000000000000;window.__products[0].price=9000000000000000;document.querySelector('[data-nav="cashier"]').click();`);
  await waitFor(`document.querySelector('#product-list button[data-action="add"]')!==null`);
  await addCart();
  await evaluate(`document.querySelector('#pay').click();document.querySelector('[data-tender="exact"]').click();`);
  assert.equal(await evaluate(`document.querySelector('#payment-submit').disabled`), false);
  assert.ok(await evaluate(`document.querySelector('#payment-dialog').scrollWidth<=document.querySelector('#payment-dialog').clientWidth`), 'Largest supported amount overflows payment dialog');
  await evaluate(`document.querySelector('#payment-cancel').click();window.__rejectQuote='product_changed';${quantity}.value='1,000';${quantity}.dispatchEvent(new Event('input',{bubbles:true}));`);
  await waitFor(`document.querySelector('#quote-notice').textContent.includes('berubah')`);
  assert.equal(await evaluate(`document.querySelector('#pay').disabled`), true);
  assert.deepEqual(errors, []);
  console.log('UI tests passed: setup regression, product entry, decimal quantity/discount parsing, escaped text, checkout_unknown and dropped acknowledgement same-key recovery, history, device settings with live preview/logo/scanner, auto-print outcomes, SALINAN reprint, stale-product blocking and desktop layouts. Financial totals are mocked; native tests verify Zig/SQLite.');
  const styles = await readFile(path.join(root, 'ui/styles.css'), 'utf8');
  assert.match(styles, /prefers-reduced-motion/);
  const exited = once(browser, 'exit');
  await send('Browser.close');
  await exited;
} finally {
  if (browser.exitCode === null) browser.kill();
  for (const entry of pending.values()) clearTimeout(entry.timer);
}
