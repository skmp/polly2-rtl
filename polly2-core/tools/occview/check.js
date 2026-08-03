// Headless check of occview's parser + event rendering, per the project's
// "eval the extracted <script> with a stubbed DOM" pattern.
const fs = require('fs');
const VIEW = '/home/skmp/projects/dreamster/polly2-rtl/polly2-core/tools/occview/index.html';
const html = fs.readFileSync(VIEW, 'utf8');
const script = html.substring(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));

// Canvas ops are recorded for assertions, but a full-run repaint of a real trace
// emits millions - cap the buffer so the harness measures the viewer, not itself.
const ops = [];
let recording = true;
const OPS_CAP = 400000;
function mkCtx() {
  const st = {};
  return new Proxy(st, {
    get(t, k) {
      if (k === 'canvas') return { width: 0, height: 0 };
      if (typeof k === 'symbol') return undefined;
      if (k in t) return t[k];
      return (...a) => { if (recording && ops.length < OPS_CAP) ops.push([k, ...a]); };
    },
    set(t, k, v) { t[k] = v; return true; }
  });
}
function mkEl(id) {
  const el = {
    id, style: {}, classList: { add(){}, remove(){} }, children: [],
    clientWidth: 1200, width: 0, height: 0, value: 0, textContent: '', innerHTML: '',
    getContext: () => mkCtx(),
    addEventListener(){}, appendChild(c){ el.children.push(c); },
    setAttribute(){}, getBoundingClientRect: () => ({left:0, top:0, width:1200, height:400}),
    parentElement: { clientWidth: 1200 },
  };
  return el;
}
const els = {};
const pending = [];
function drain() { while (pending.length) pending.shift()(); }
const sandbox = {
  document: {
    getElementById: (id) => els[id] || (els[id] = mkEl(id)),
    createElement: () => mkEl('new'),
    createElementNS: () => mkEl('svg'),
    body: mkEl('body'),
    addEventListener(){},
  },
  window: { addEventListener(){}, devicePixelRatio: 1 },
  location: { search: '', protocol: 'http:' },
  URLSearchParams,
  alert: (m) => { throw new Error('ALERT: ' + m); },
  // The parser is chunked and re-schedules itself via setTimeout. Running the
  // callback inline would recurse once per 2 MB chunk (and blow the stack/heap on a
  // real trace), so queue instead and drain after loadText returns.
  setTimeout: (f) => { pending.push(f); },
  console, Math, JSON, Array, Float64Array, Float32Array, Uint32Array,
  Infinity, NaN, parseInt, parseFloat, isNaN, Object, String, Number, Set, Map,
};
// expose the internals the checks need by appending an export expression
const factory = new Function(...Object.keys(sandbox), script + `
  ; return { DB, parseLog, evRange, drawTracks, buildEvLegend, paintEvRow, evRowAt,
             evRowTop, setView: (a,b) => { view.t0=a; view.t1=b; },
             getView: () => view, computeOrder };
`);
const M = factory(...Object.values(sandbox));

// parse + minimal post-load setup, skipping buildSvg/buildOverview (heavy, and not
// what these checks are about)
function load(text) {
  let done = false;
  M.parseLog(text, () => { done = true; }, () => {});
  while (pending.length && !done) pending.shift()();
  M.DB.order = M.computeOrder();
  M.setView(0, M.DB.total);
}
let ok = true;
const chk = (name, cond, extra) => {
  console.log((cond ? '  ok   ' : '  FAIL ') + name + (extra !== undefined ? '  -> ' + extra : ''));
  if (!cond) ok = false;
};

// ============================ synthetic log ============================
function mklog() {
  const L = ['POLLY2OCC 1'];
  for (let u = 0; u < 21; u++) L.push(`U ${u} UNIT${u}`);
  L.push('V 0 phase');
  L.push('T 0 TC$MISS stall');
  L.push('T 1 TC$PREFETCH info');
  L.push('T 2 TC$PFWAIT stall');
  L.push('T 3 VQ$MISS stall');
  L.push('R 0');
  for (let c = 0; c < 2000; c += 100) L.push(`@${c} 0000000001 v0=${c%3}`);
  // emitted in CLOSE order -> deliberately NOT in start order
  L.push('X 0 500 40 12340');
  L.push('X 0 100 60 abcd0');
  L.push('X 1 300 250 55500');
  L.push('X 2 900 30 12340');
  L.push('X 3 1200 15 77700');
  L.push('X 0 1500 300 99900');
  L.push('D 1999');
  return L.join('\n') + '\n';
}

console.log('== parse (synthetic) ==');
load(mklog());
const db = M.DB;
chk('4 event tracks', db.ev.length === 4, db.ev.length);
const t0 = db.ev[0];
chk('track0 name', t0.name === 'TC$MISS', t0.name);
chk('track0 kind', t0.kind === 'stall', t0.kind);
chk('track1 kind info', db.ev[1].kind === 'info', db.ev[1].kind);
chk('track0 count', t0.n === 3, t0.n);
chk('track0 SORTED by start', t0.c0[0]===100 && t0.c0[1]===500 && t0.c0[2]===1500,
    Array.from(t0.c0).join(','));
chk('len follows the sort', t0.len[0]===60 && t0.len[1]===40 && t0.len[2]===300,
    Array.from(t0.len).join(','));
chk('addr follows the sort',
    t0.addr[0]===0xabcd0 && t0.addr[1]===0x12340 && t0.addr[2]===0x99900,
    Array.from(t0.addr).map(a=>a.toString(16)).join(','));
chk('track0 cycles', t0.cycles === 400, t0.cycles);
chk('track0 maxLen', t0.maxLen === 300, t0.maxLen);
chk('total covers last event end', db.total >= 1800, db.total);

console.log('== evRange ==');
{
  const [i,j] = M.evRange(t0, 1600, 1610);   // inside the 1500..1800 episode
  let found = false;
  for (let k=i;k<j;k++) if (t0.c0[k]===1500) found = true;
  chk('finds episode overlapping the query start', found, `[${i},${j})`);
  const [a,b] = M.evRange(t0, 0, 2000);
  chk('full range covers all 3', b-a === 3, `[${a},${b})`);
}

console.log('== coverage-proportional height ==');
{
  // paint one row directly at 200 cyc/px and read the rects back out
  const rowH = 20;
  ops.length = 0;
  M.paintEvRow(mkCtx(), t0, 0, 2000, 0, 10, 0, rowH);
  // fillRects after the first (the background) are the coverage runs
  const rects = ops.filter(o => o[0] === 'fillRect').slice(1)
                   .map(o => ({ x: o[1], y: o[2], w: o[3], h: o[4] }));
  const hAt = (px) => {
    for (const r of rects) if (px >= r.x && px < r.x + r.w) return r.h;
    return 0;
  };
  // px0: 60/200 = 30% -> round(0.30*20) = 6
  chk('px0 height 30% of row', hAt(0) === 6, hAt(0));
  // px2: 40/200 = 20% -> 4
  chk('px2 height 20% of row', hAt(2) === 4, hAt(2));
  // px7: 100/200 = 50% -> 10
  chk('px7 height 50% of row', hAt(7) === 10, hAt(7));
  // px8: fully covered -> full row height
  chk('px8 full height', hAt(8) === rowH, hAt(8));
  // px9: nothing
  chk('px9 empty', hAt(9) === 0, hAt(9));
  // partial columns are BOTTOM-ALIGNED: a half-height mark's top is at rowH/2 and
  // every bar shares the row's bottom edge as a baseline
  const r7 = rects.find(r => 7 >= r.x && 7 < r.x + r.w);
  chk('partial column bottom-aligned', r7 && r7.y === rowH - 10, r7 && r7.y);
  chk('all bars share the bottom baseline',
      rects.every(r => Math.abs((r.y + r.h) - rowH) < 1e-9),
      rects.map(r => r.y + r.h).join(','));
}
{
  // many short events in one column must sum, not saturate
  const rowH = 20;
  const fake = { name:'X', kind:'stall', n:4, maxLen:5,
                 c0: Float64Array.from([0, 20, 40, 60]),
                 len: Float64Array.from([5, 5, 5, 5]),
                 addr: Float64Array.from([1,2,3,4]), cycles: 20 };
  ops.length = 0;
  M.paintEvRow(mkCtx(), fake, 0, 100, 0, 1, 0, rowH);   // one column, 20/100 covered
  const rects = ops.filter(o => o[0] === 'fillRect').slice(1);
  chk('4 short events sum to 20% height', rects.length && rects[0][4] === 4,
      rects.length ? rects[0][4] : 'none');
}

console.log('== rendering ==');
{
  ops.length = 0; M.drawTracks();
  const texts = ops.filter(o=>o[0]==='fillText').map(o=>String(o[1]));
  chk('unit rows drawn', texts.includes('UNIT0'));
  chk('event row names drawn', texts.includes('TC$MISS') && texts.includes('VQ$MISS'));
  chk('fillRects emitted', ops.some(o=>o[0]==='fillRect'));
}
{
  M.setView(1450, 1900);                     // ~0.4 cyc/px -> the 300c span is wide
  ops.length = 0; M.drawTracks();
  const texts = ops.filter(o=>o[0]==='fillText').map(o=>String(o[1]));
  chk('address label when zoomed in', texts.some(t=>t.includes('0x99900')),
      texts.filter(t=>t.startsWith('0x')).join('|'));
  chk('duration shown with the address', texts.some(t=>t.includes('300c')),
      texts.filter(t=>t.startsWith('0x')).join('|'));
}
{
  M.setView(0, 2000);
  ops.length = 0; M.drawTracks();
  const texts = ops.filter(o=>o[0]==='fillText').map(o=>String(o[1]));
  const addrs = texts.filter(t=>t.startsWith('0x'));
  chk('short spans unlabelled at full zoom-out', !addrs.some(t=>t.includes('12340')),
      addrs.join('|'));
}

console.log('== row hit-testing ==');
{
  const top = M.evRowTop();
  chk('above rows -> -1', M.evRowAt(top-20) === -1, M.evRowAt(top-20));
  chk('row0', M.evRowAt(top+2) === 0, M.evRowAt(top+2));
  chk('row3', M.evRowAt(top+3*22+2) === 3, M.evRowAt(top+3*22+2));
  chk('past end -> -1', M.evRowAt(top+9*22) === -1, M.evRowAt(top+9*22));
}

// ============================ backwards compat ============================
console.log('== old log without T/X records ==');
{
  const L = ['POLLY2OCC 1'];
  for (let u=0;u<21;u++) L.push(`U ${u} UNIT${u}`);
  L.push('V 0 phase', 'R 0', '@0 0000000001 v0=1', '@50 0000000002 v0=2', 'D 99');
  load(L.join('\n')+'\n');
  chk('no event tracks', M.DB.ev.length === 0, M.DB.ev.length);
  ops.length = 0;
  M.drawTracks();
  chk('draws without throwing', true);
}

// ============================ real trace ============================
const REAL = process.env.OCC_LOG || '/home/skmp/projects/dreamster/polly2-rtl/polly2-core/sc_ingame.log';
if (fs.existsSync(REAL)) {
  console.log('== real trace: sc_ingame.log ==');
  const t = Date.now();
  load(fs.readFileSync(REAL, 'utf8'));
  const d2 = M.DB;
  console.log(`  parsed in ${Date.now()-t} ms, total=${d2.total.toLocaleString()} cycles`);
  chk("6 event tracks", d2.ev.length === 6, d2.ev.length);
  let tot = 0;
  for (const tr of d2.ev) {
    tot += tr.n;
    // the invariant every binary search depends on
    let sorted = true, badLen = 0, over = 0;
    for (let k=0;k<tr.n;k++) {
      if (k && tr.c0[k] < tr.c0[k-1]) sorted = false;
      if (!(tr.len[k] > 0)) badLen++;
      if (tr.c0[k] + tr.len[k] > d2.total) over++;
    }
    chk(`${tr.name}: sorted by start`, sorted);
    chk(`${tr.name}: all durations > 0`, badLen === 0, badLen);
    chk(`${tr.name}: all within the run`, over === 0, over);
    console.log(`       ${tr.n.toLocaleString()} events, ${tr.cycles.toLocaleString()} cyc` +
                ` (${(tr.cycles/d2.total*100).toFixed(1)}% of run), avg ${(tr.cycles/tr.n).toFixed(1)},` +
                ` max ${tr.maxLen}`);
  }

  // FETCH and PFWAIT must each be a subset of MISS in time, and disjoint from each
  // other: a miss either issues its own burst or rides a prefetch, never both for
  // the same line.
  const byName = (n) => d2.ev.find(e => e.name === n);
  const miss = byName('TC$MISS');
  for (const sub of ['TC$FETCH', 'TC$PFWAIT']) {
    const t = byName(sub);
    if (!t || !t.n) { console.log(`  skip  ${sub}: no events`); continue; }
    let inside = 0;
    for (let k=0;k<t.n;k++) {
      const [i,j] = M.evRange(miss, t.c0[k], t.c0[k]+t.len[k]);
      for (let m=i;m<j;m++)
        if (miss.c0[m] <= t.c0[k] && miss.c0[m]+miss.len[m] >= t.c0[k]+t.len[k]) { inside++; break; }
    }
    chk(`every ${sub} lies inside a MISS episode`, inside === t.n, `${inside}/${t.n}`);
  }
  {
    const f = byName('TC$FETCH'), w = byName('TC$PFWAIT');
    if (f && w && f.n && w.n) {
      let ov = 0;
      for (let k=0;k<f.n;k++) {
        const [i,j] = M.evRange(w, f.c0[k], f.c0[k]+f.len[k]);
        for (let m=i;m<j;m++)
          if (w.c0[m] < f.c0[k]+f.len[k] && w.c0[m]+w.len[m] > f.c0[k]) ov++;
      }
      chk('FETCH and PFWAIT never overlap', ov === 0, ov);
      // each MISS episode is served by at least one of the two
      chk('FETCH+PFWAIT count covers MISS count', f.n + w.n >= miss.n,
          `${f.n}+${w.n}=${f.n+w.n} vs ${miss.n} misses`);
      const inner = f.cycles + w.cycles;
      console.log(`       MISS ${miss.cycles.toLocaleString()} cyc = FETCH ${f.cycles.toLocaleString()}` +
                  ` + PFWAIT ${w.cycles.toLocaleString()} + ${(miss.cycles-inner).toLocaleString()} overhead` +
                  ` (${((miss.cycles-inner)/miss.cycles*100).toFixed(1)}% arbiter wait + retest)`);
      chk('subsets do not exceed the parent', inner <= miss.cycles, inner);
    }
  }
  // no self-overlap within a track (episodes are serial per cache)
  for (const tr of d2.ev) {
    let ov = 0;
    for (let k=1;k<tr.n;k++) if (tr.c0[k] < tr.c0[k-1] + tr.len[k-1]) ov++;
    chk(`${tr.name}: episodes do not overlap`, ov === 0, ov);
  }
  {
    const t2 = Date.now();
    M.setView(0, d2.total); ops.length = 0; recording = false;
    M.drawTracks(); recording = true;
    console.log(`  full-run render in ${Date.now()-t2} ms, ${ops.length.toLocaleString()} canvas ops`);
    chk('full-run render finishes', true);
  }
  {
    const mid = Math.floor(d2.total/2);
    const t3 = Date.now();
    M.setView(mid, mid+3000); ops.length = 0; M.drawTracks();
    const texts = ops.filter(o=>o[0]==='fillText').map(o=>String(o[1]));
    console.log(`  zoomed render in ${Date.now()-t3} ms; ` +
                `${texts.filter(x=>x.startsWith('0x')).length} address labels`);
  }
} else console.log('== real trace absent, skipped ==');

console.log(ok ? '\nALL CHECKS PASSED' : '\nFAILURES PRESENT');
process.exit(ok ? 0 : 1);
