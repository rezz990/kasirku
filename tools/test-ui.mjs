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
  const shifts = window.__shifts = []; let entrySerial = 0;
  window.__cashErrorOnce = null;
  window.__importData = ''; window.__importToken = null; window.__importInvalid = false;
  window.__exportError = null;
  const openShift = () => shifts.find(s=>!s.closed_at);
  const summary = s => {
    const shiftSales = sales.filter(x=>x.shift_id===s.id);
    const cashSales = shiftSales.reduce((n,x)=>n+x.totals.total,0);
    const cashIn = s.entries.filter(e=>e.kind==='in').reduce((n,e)=>n+e.amount,0);
    const cashOut = s.entries.filter(e=>e.kind==='out').reduce((n,e)=>n+e.amount,0);
    const expected = s.opening_cash+cashSales+cashIn-cashOut;
    return {id:s.id,opened_at:s.opened_at,closed_at:s.closed_at,opening_cash:s.opening_cash,sale_count:shiftSales.length,sales_total:cashSales,cash_sales:cashSales,cash_in:cashIn,cash_out:cashOut,expected_cash:expected,counted_cash:s.counted_cash,difference:s.counted_cash===null?null:s.counted_cash-expected,close_note:s.close_note,entries:s.entries};
  };
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
      else if (message.command === 'product.import_begin') { window.__importData='';window.__importToken='0123456789abcdef0123456789abcdef';result={token:window.__importToken}; }
      else if (message.command === 'product.import_chunk') { window.__importData+=message.payload.data_base64;result={received:window.__importData.length}; }
      else if (message.command === 'product.import_preview') {
        if(window.__importInvalid) result={valid:false,row_count:1,error_count:1,rows:[],errors:[{line:3,code:'invalid_product'}]};
        else result={valid:true,row_count:2,error_count:0,rows:[{line:2,product:{name:'Produk impor A',price:12000}},{line:3,product:{name:'Produk impor B',price:8000}}],errors:[]};
      }
      else if (message.command === 'product.import_apply') {
        for(const [name,price] of [['Produk impor A',12000],['Produk impor B',8000]]) products.push({id:products.length+1,revision:1,name,sku:'',barcode:'',category:'Impor',unit:'pcs',price,cost:0,stock_milli:null,min_stock_milli:null});
        result={imported:2};window.__importToken=null;
      }
      else if (message.command === 'product.import_cancel') { window.__importToken=null;result={cancelled:true}; }
      else if (message.command === 'csv.export') { if(window.__exportError) error={code:window.__exportError}; else result={exported:true}; }
      else if (message.command === 'report.daily_print') result={submitted:true};
      else if (message.command === 'sale.checkout' && window.__checkoutErrorOnce) { error={code:window.__checkoutErrorOnce};window.__checkoutErrorOnce=null; }
      else if (message.command === 'sale.checkout' && !openShift()) error={code:'shift_required'};
      else if (message.command === 'shift.current') { const s=openShift(); result={shift:s?summary(s):null}; }
      else if (message.command === 'shift.open') {
        if (openShift()) error={code:'shift_open'};
        else { const s={id:shifts.length+1,opened_at:'2026-10-27T08:00:00Z',closed_at:null,opening_cash:message.payload.opening_cash,counted_cash:null,close_note:'',entries:[]}; shifts.push(s); result={shift:summary(s)}; }
      }
      else if (message.command === 'shift.cash') {
        const s=openShift();
        if(!s) error={code:'shift_required'};
        else if(window.__cashErrorOnce){error={code:window.__cashErrorOnce};window.__cashErrorOnce=null;}
        else {
          let e=s.entries.find(e=>e.entry_key===message.payload.entry_key);
          if(!e){e={id:++entrySerial,entry_key:message.payload.entry_key,created_at:'2026-10-27T09:00:00Z',kind:message.payload.kind,amount:message.payload.amount,category:message.payload.category,note:message.payload.note};s.entries.push(e);}
          result={shift:summary(s)};
        }
      }
      else if (message.command === 'shift.close') {
        const s=shifts.find(s=>s.id===message.payload.id);
        if(!s) error={code:'shift_not_found'};
        else if(s.closed_at) error={code:'shift_closed'};
        else {s.closed_at='2026-10-27T17:00:00Z';s.counted_cash=message.payload.counted_cash;s.close_note=message.payload.note;result={shift:summary(s)};}
      }
      else if (message.command === 'shift.print') {
        const c=window.__deviceConfig;
        if(!c.printer_name&&!c.tcp_host&&!c.file_path) error={code:'invalid_device_config'};
        else result={submitted:true};
      }
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
          if(!sale){sale={id:sales.length+1,shift_id:openShift().id,checkout_id:message.payload.checkout_id,number:'INV-20261027-0001',created_at:'2026-10-27T10:00:00Z',business_name:business.name,business_address:business.address,items,totals,tendered:message.payload.tendered,change:message.payload.tendered-window.__quoteTotal};sales.push(sale);}
          result={sale};
          if (window.__unknownCheckoutAck) { window.__unknownCheckoutAck=false; result=undefined; error={code:'checkout_unknown'}; }
        }
      }
      else if (message.command === 'sale.list') result = { sales: sales.map(s=>({id:s.id,number:s.number,created_at:s.created_at,total:s.totals.total,tendered:s.tendered,change:s.change,item_count:s.items.length})), has_more: false };
      else if (message.command === 'sale.get') result={sale:sales.find(s=>s.id===message.payload.id)};
      else if (message.command === 'report.dashboard') {
        const total=sales.reduce((n,s)=>n+s.totals.total,0);
        result={date:message.payload.date,sale_count:sales.length,sales_total:total,average_sale:sales.length?Math.round(total/sales.length):0,revenue:total,cogs:0,gross_profit:total,hours:Array.from({length:24},(_,hour)=>({hour,sale_count:hour===10?sales.length:0,sales_total:hour===10?total:0})),top_products:sales.length?products.filter(p=>!p.archived).map(p=>({product_id:p.id,name:p.name,unit:p.unit,quantity_milli:500,revenue:total,cogs:0,gross_profit:total})):[],low_stock:products.filter(p=>!p.archived&&p.stock_milli!==null&&p.min_stock_milli!==null&&p.stock_milli<=p.min_stock_milli).map(p=>({product_id:p.id,name:p.name,unit:p.unit,stock_milli:p.stock_milli,min_stock_milli:p.min_stock_milli}))};
      }
      else if (message.command === 'report.sales') {
        const total=sales.reduce((n,s)=>n+s.totals.total,0), group=message.payload.group_by;
        result={from:message.payload.from,to:message.payload.to,group_by:group,sale_count:sales.length,sales_total:total,revenue:total,cogs:0,gross_profit:total,groups:sales.length?[{key:group==='day'?'2026-10-27':group==='product'?products[0].name:'Minuman',product_id:group==='product'?products[0].id:null,unit:group==='product'?products[0].unit:'',sale_count:sales.length,quantity_milli:500,revenue:total,cogs:0,gross_profit:total}]:[],has_more:false};
      }
      else if (message.command === 'report.profit') {
        const total=sales.reduce((n,s)=>n+s.totals.total,0), entries=shifts.flatMap(s=>s.entries).filter(e=>e.kind==='out'), expense=entries.reduce((n,e)=>n+e.amount,0);
        result={from:message.payload.from,to:message.payload.to,revenue:total,cogs:0,gross_profit:total,expense_total:expense,net_profit:total-expense,expense_categories:entries.map(e=>({category:e.category,amount:e.amount})),has_more:false};
      }
      else if (message.command === 'report.stock') {
        const rows=products.filter(p=>!p.archived).map(p=>({product_id:p.id,name:p.name,category:p.category,unit:p.unit,cost:p.cost,stock_milli:p.stock_milli,min_stock_milli:p.min_stock_milli,stock_value:p.stock_milli===null?0:Math.round(p.cost*p.stock_milli/1000),last_sold_at:sales.length?'2026-10-27T10:00:00Z':null,low_stock:p.stock_milli!==null&&p.min_stock_milli!==null&&p.stock_milli<=p.min_stock_milli,dead_stock:false}));
        const filtered=message.payload.filter==='low'?rows.filter(p=>p.low_stock):message.payload.filter==='dead'?rows.filter(p=>p.dead_stock):rows;
        result={filter:message.payload.filter,total_products:rows.length,tracked_products:rows.filter(p=>p.stock_milli!==null).length,low_stock_count:rows.filter(p=>p.low_stock).length,dead_stock_count:0,stock_value:rows.reduce((n,p)=>n+p.stock_value,0),products:filtered,has_more:false};
      }
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
  await evaluate(`document.querySelector('#product-name').value='<img src=x onerror=alert(1)>';document.querySelector('#product-sku').value='UI-01';document.querySelector('#product-unit').value='kg';document.querySelector('#product-price').value='-1';document.querySelector('#product-cost').value='5000';document.querySelector('#product-track-stock').click();document.querySelector('#product-stock').value='2,5';document.querySelector('#product-min-stock').value='3';document.querySelector('#product-form').requestSubmit();`);
  await waitFor(`document.querySelector('#product-notice').hidden===false`);
  assert.equal(await evaluate(`window.__products.length`), 0);
  await evaluate(`document.querySelector('#product-price').value='9900';document.querySelector('#product-form').requestSubmit();`);
  await waitFor(`window.__products.length===1 && document.querySelector('#product-fields').disabled===false`);
  assert.equal(await evaluate(`window.__products[0].stock_milli`), 2500);
  assert.equal(await evaluate(`window.__products[0].min_stock_milli`), 3000);
  await evaluate(`document.querySelector('[data-nav="cashier"]').click();`);
  await waitFor(`document.querySelector('#product-list button')!==null`);
  assert.equal(await evaluate(`document.querySelector('#product-list img')!==null`), false);
  assert.equal(await evaluate(`document.querySelector('#product-list .stock-badge').textContent`), 'Stok menipis');
  await call('Input.dispatchKeyEvent', { type:'keyDown', key:'F2', code:'F2', windowsVirtualKeyCode:113 });
  await call('Input.dispatchKeyEvent', { type:'keyUp', key:'F2', code:'F2', windowsVirtualKeyCode:113 });
  assert.equal(await evaluate(`document.activeElement.id`), 'product-search');
  const addCart = async () => {
    await evaluate(`document.querySelector('#product-list button[data-action="add"]').click();`);
    await waitFor(`document.querySelector('#pay').disabled===false`);
  };
  const quantity = `document.querySelector('#cart-lines input[inputmode="decimal"]')`;
  await waitFor(`document.querySelector('#shift-gate').hidden===false`);
  await evaluate(`document.querySelector('#product-list button[data-action="add"]').click();`);
  await waitFor(`window.__requests.some(r=>r.command==='cart.quote')`);
  assert.equal(await evaluate(`document.querySelector('#pay').disabled`), true);
  await evaluate(`document.querySelector('#shift-gate-action').click();`);
  await waitFor(`document.querySelector('#shift-screen').hidden===false && document.querySelector('#shift-open-form').hidden===false`);
  await evaluate(`document.querySelector('#shift-opening-cash').value='50000';document.querySelector('#shift-open-form').requestSubmit();`);
  await waitFor(`document.querySelector('#shift-close-card').hidden===false`);
  assert.equal(await evaluate(`window.__shifts[0].opening_cash`), 50000);
  await evaluate(`document.querySelector('[data-nav="cashier"]').click();`);
  await waitFor(`document.querySelector('#shift-gate').hidden===true && document.querySelector('#product-list button[data-action="add"]')!==null`);
  await evaluate(`window.confirm=()=>true;document.querySelector('#cart-clear').click();`);
  await waitFor(`document.querySelector('#cart-lines').children.length===0`);
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
  await evaluate(`document.querySelector('[data-nav="shift"]').click();`);
  await waitFor(`document.querySelector('#shift-screen').hidden===false && document.querySelector('#shift-cash-card').hidden===false`);
  await evaluate(`window.__cashErrorOnce='timeout';document.querySelector('input[name="cash_kind"][value="out"]').checked=true;document.querySelector('#shift-cash-amount').value='2000';document.querySelector('#shift-cash-category').value='Belanja es';document.querySelector('#shift-cash-note').value='Pasar pagi';document.querySelector('#shift-cash-form').requestSubmit();`);
  await waitFor(`document.querySelector('#shift-cash-notice').textContent.includes('merespons') && document.querySelector('#shift-cash-fields').disabled===false`);
  await evaluate(`document.querySelector('#shift-cash-form').requestSubmit();`);
  await waitFor(`document.querySelector('#shift-cash-notice').textContent.includes('tercatat')`);
  assert.equal(await evaluate(`window.__shifts[0].entries.length`), 1);
  const cashKeys = await evaluate(`window.__requests.filter(r=>r.command==='shift.cash').map(r=>r.payload.entry_key)`);
  assert.equal(cashKeys.length, 2);
  assert.equal(cashKeys[0], cashKeys[1]);
  assert.equal(await evaluate(`document.querySelector('#shift-entries').children.length`), 1);
  assert.equal(await evaluate(`document.querySelector('#shift-summary').textContent.includes('2.000')`), true);
  await evaluate(`document.querySelector('#shift-counted').value='47000';document.querySelector('#shift-counted').dispatchEvent(new Event('input',{bubbles:true}));`);
  assert.match(await evaluate(`document.querySelector('#shift-difference').textContent`), /-/);
  for (const [width, height] of [[1366,768],[1000,640]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(path.join(cache, `shift-ui-${width}x${height}.png`), Buffer.from(screenshot.data,'base64'));
  }
  await evaluate(`window.confirm=()=>true;document.querySelector('#shift-close-note').value='Kurang seribu';document.querySelector('#shift-close-form').requestSubmit();`);
  await waitFor(`document.querySelector('#shift-open-form').hidden===false && document.querySelector('#shift-closed-copy').hidden===false`);
  assert.equal(await evaluate(`window.__shifts[0].closed_at`), '2026-10-27T17:00:00Z');
  assert.equal(await evaluate(`document.querySelector('#shift-summary').textContent.includes('Kurang seribu')`), true);
  await evaluate(`document.querySelector('#shift-print').click();`);
  await waitFor(`document.querySelector('#shift-print-notice').textContent.includes('terkirim')`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='shift.print').length`), 1);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='shift.print')[0].payload.id`), 1);
  await evaluate(`document.querySelector('#shift-opening-cash').value='10000';document.querySelector('#shift-open-form').requestSubmit();`);
  await waitFor(`document.querySelector('#shift-close-card').hidden===false`);
  assert.equal(await evaluate(`window.__shifts.length`), 2);
  await evaluate(`document.querySelector('[data-nav="reports"]').click();`);
  await waitFor(`document.querySelector('#report-screen').hidden===false && document.querySelector('#dashboard-metrics').children.length===6 && document.querySelector('#report-notice').hidden===true`);
  assert.equal(await evaluate(`document.querySelector('#dashboard-hours').children.length`), 24);
  assert.equal(await evaluate(`document.querySelector('#dashboard-low-stock').children.length`), 1);
  assert.equal(await evaluate(`document.querySelector('#dashboard-top-products img')!==null`), false);
  await evaluate(`document.querySelector('[data-report-view="sales"]').click();`);
  await waitFor(`document.querySelector('#report-sales').hidden===false && document.querySelector('#sales-metrics').children.length===5`);
  await evaluate(`document.querySelector('#sales-group').value='product';document.querySelector('#sales-from').value='2026-10-28';document.querySelector('#sales-to').value='2026-10-27';document.querySelector('#sales-form').requestSubmit();`);
  await waitFor(`document.querySelector('#report-notice').textContent.includes('tidak valid')`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='report.sales').length`), 1);
  await evaluate(`document.querySelector('#sales-from').value='2026-10-27';document.querySelector('#sales-to').value='2026-10-27';document.querySelector('#sales-form').requestSubmit();`);
  await waitFor(`document.querySelector('#report-notice').hidden===true && document.querySelector('#sales-groups').children.length===1`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='report.sales').at(-1).payload.group_by`), 'product');
  assert.equal(await evaluate(`document.querySelector('#sales-groups img')!==null`), false);
  await evaluate(`document.querySelector('[data-report-view="profit"]').click();`);
  await waitFor(`document.querySelector('#report-profit').hidden===false && document.querySelector('#profit-metrics').children.length===5`);
  assert.equal(await evaluate(`document.querySelector('#profit-categories').textContent.includes('Belanja es')`), true);
  await evaluate(`document.querySelector('[data-report-view="stock"]').click();`);
  await waitFor(`document.querySelector('#report-stock').hidden===false && document.querySelector('#stock-products').children.length===1`);
  assert.equal(await evaluate(`document.querySelector('#stock-products .stock-badge').textContent`), 'Stok menipis');
  for (const [width, height] of [[1366,768],[1000,640]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
    assert.equal(await evaluate(`document.querySelector('#report-refresh').getBoundingClientRect().bottom<=innerHeight`), true);
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(path.join(cache, `report-ui-${width}x${height}.png`), Buffer.from(screenshot.data,'base64'));
  }
  await evaluate(`document.querySelector('[data-report-view="dashboard"]').click();`);
  await waitFor(`document.querySelector('#report-dashboard').hidden===false && document.querySelector('#report-notice').hidden===true`);
  await evaluate(`document.querySelector('#dashboard-stock-action').click();`);
  await waitFor(`document.querySelector('#report-stock').hidden===false && document.querySelector('#report-notice').hidden===true`);
  assert.equal(await evaluate(`document.querySelector('#stock-filter').value`), 'low');
  await evaluate(`document.querySelector('#report-export').click();`);
  await waitFor(`document.querySelector('#report-notice').textContent.includes('berhasil')`);
  assert.deepEqual(await evaluate(`window.__requests.filter(r=>r.command==='csv.export').at(-1).payload`), {kind:'stock',filter:'low'});
  await evaluate(`document.querySelector('[data-report-view="dashboard"]').click();`);
  await waitFor(`document.querySelector('#report-dashboard').hidden===false && document.querySelector('#report-notice').hidden===true`);
  await evaluate(`document.querySelector('#daily-print').click();`);
  await waitFor(`document.querySelector('#report-notice').textContent.includes('terkirim')`);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='report.daily_print').length`), 1);
  await evaluate(`document.querySelector('#report-export').click();`);
  await waitFor(`document.querySelector('#report-notice').textContent.includes('berhasil')`);
  assert.deepEqual(await evaluate(`window.__requests.filter(r=>r.command==='csv.export').at(-1).payload`), {kind:'dashboard',date:await evaluate(`document.querySelector('#dashboard-date').value`)});
  await evaluate(`document.querySelector('[data-nav="products"]').click();`);
  await waitFor(`document.querySelector('#product-data-tools').hidden===false`);
  const chooseCsv = `(()=>{const input=document.querySelector('#product-import-file');const transfer=new DataTransfer();transfer.items.add(new File(['name,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\\n'],'produk.csv',{type:'text/csv'}));input.files=transfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));})()`;
  await evaluate(`window.__importInvalid=true;${chooseCsv}`);
  await waitFor(`document.querySelector('#import-preview').hidden===false && document.querySelector('#import-apply').disabled===true`);
  assert.match(await evaluate(`document.querySelector('#import-errors').textContent`), /Baris 3/);
  await evaluate(`window.__importInvalid=false;${chooseCsv}`);
  await waitFor(`document.querySelector('#import-preview').hidden===false && document.querySelector('#import-apply').disabled===false`);
  assert.equal(await evaluate(`document.querySelector('#import-rows').children.length`), 2);
  assert.equal(await evaluate(`window.__requests.filter(r=>r.command==='product.import_chunk').length>=2`), true);
  await evaluate(`document.querySelector('#import-apply').click();`);
  await waitFor(`document.querySelector('#import-notice').textContent.includes('2 produk berhasil')`);
  assert.equal(await evaluate(`window.__products.filter(p=>p.category==='Impor').length`), 2);
  await waitFor(`document.querySelector('#product-export').disabled===false`);
  await evaluate(`window.__exportError='export_cancelled';document.querySelector('#product-export').click();`);
  await waitFor(`window.__requests.filter(r=>r.command==='csv.export').length===3`);
  await waitFor(`document.querySelector('#import-notice').textContent.includes('dibatalkan')`);
  assert.equal(await evaluate(`document.querySelector('#import-notice').classList.contains('error')`), false);
  await waitFor(`document.querySelector('#product-export').disabled===false`);
  await evaluate(`window.__exportError=null;document.querySelector('#product-export').click();`);
  await waitFor(`document.querySelector('#import-notice').textContent.includes('berhasil')`);
  assert.deepEqual(await evaluate(`window.__requests.filter(r=>r.command==='csv.export').at(-1).payload`), {kind:'products'});
  assert.deepEqual(errors, []);
  console.log('UI tests passed: setup regression, product entry with minimum stock and low-stock badges, decimal quantity/discount parsing, escaped text, checkout recovery, history, device settings, auto-print and reprint outcomes, shift workflows, dashboard/sales/profit/stock reports with validation, CSV import preview/apply/export, daily thermal action, and desktop layouts. Financial totals are mocked; native tests verify Zig/SQLite.');
  const styles = await readFile(path.join(root, 'ui/styles.css'), 'utf8');
  assert.match(styles, /prefers-reduced-motion/);
  const exited = once(browser, 'exit');
  await send('Browser.close');
  await exited;
} finally {
  if (browser.exitCode === null) browser.kill();
  for (const entry of pending.values()) clearTimeout(entry.timer);
}
