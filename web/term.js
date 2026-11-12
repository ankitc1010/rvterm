// Page glue for rvterm: restores the booted-Linux snapshot, runs the emulator in short slices,
// draws dirty terminal rows on a canvas and turns keys into bytes for the guest.
'use strict';

const EXIT_BUDGET = 0, EXIT_IDLE = 1;
const SLICE = 50000; // instructions per run() call
const FRAME_MS = 12; // emulator time per animation frame, leaving room to draw
// While the guest idles, wake at most every 30-100 ms: Linux catches up on late timer ticks,
// and keystrokes wake the loop immediately, so this only trims idle CPU (~116 to ~30 wakes/s).
const IDLE_MIN_MS = 30, IDLE_MAX_MS = 100;
const TYPING_MS = 500; // after a keystroke, follow the guest's own 10 ms UART polling instead
const MAX_DEBT_US = 200000; // how far guest time may run ahead to deliver keys early
const CHASE_TICKS = 6; // guest timer ticks to skip after a keystroke: UART read, then the echo
// Two machines: 64-bit Alpine Linux by default, or the small 32-bit BusyBox one with ?rv32.
// ?node picks the 64-bit snapshot with Node.js (zig build -Dnode): about 3x the download.
// ?claude picks Node.js and Claude Code on a 1 GB machine (zig build -Dclaude): desktop browsers only.
const MACHINE = /[?&]rv32\b/.test(location.search) ? '' : '64';
const VARIANT = !MACHINE ? '' : /[?&]claude\b/.test(location.search) ? 'claude' : /[?&]node\b/.test(location.search) ? 'node' : '';
const WASM = `rvterm${MACHINE}${VARIANT === 'claude' ? '-1g' : ''}.wasm`;
const SNAPSHOT = `snapshot${MACHINE}${VARIANT ? `-${VARIANT}` : ''}.bin.gz`;

// Cell layout from vt.zig: u32 codepoint, then fg, bg, attr bytes.
const BOLD = 1, DIM = 2, UNDERLINE = 4, REVERSE = 8, FG_SET = 16, BG_SET = 32;
const FG = '#d8dee9', BG = '#0b0e14';
const FONT = "'DejaVu Sans Mono', 'Droid Sans Mono', 'Liberation Mono', monospace";
const PALETTE = (() => {
  const base = ['#1c2129', '#e06c75', '#98c379', '#e5c07b', '#61afef', '#c678dd', '#56b6c2', '#d8dee9',
    '#5c6370', '#ff7a85', '#b5e890', '#ffd68a', '#7cc3ff', '#de97f0', '#7fd4de', '#ffffff'];
  const steps = [0, 95, 135, 175, 215, 255];
  for (let i = 0; i < 216; i++) base.push(`rgb(${steps[Math.floor(i / 36)]},${steps[Math.floor(i / 6) % 6]},${steps[i % 6]})`);
  for (let i = 0; i < 24; i++) base.push(`rgb(${8 + i * 10},${8 + i * 10},${8 + i * 10})`);
  return base;
})();

const statusEl = document.getElementById('status');
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d', { alpha: false });
const keyboard = document.getElementById('kbd');

// ?debug sends key, focus and input events to the dev server's /log, to see what a TV really delivers.
const DEBUG = /[?&]debug\b/.test(location.search);
let debugQueue = [], debugTimer = 0;
function debug(type, detail) {
  if (!DEBUG) return;
  debugQueue.push(Object.assign({ t: Math.round(performance.now()), type }, detail));
  if (debugTimer) return;
  debugTimer = setTimeout(() => {
    debugTimer = 0;
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/log');
    xhr.send(JSON.stringify(debugQueue.splice(0)));
  }, 300);
}
if (DEBUG) {
  const target = (e) => e.target.id || e.target.tagName;
  for (const type of ['keydown', 'keyup']) {
    document.addEventListener(type, (e) => debug(type, { key: e.key, code: e.code, keyCode: e.keyCode, target: target(e) }), true);
  }
  for (const type of ['input', 'change', 'compositionstart', 'compositionend', 'focus', 'blur']) {
    keyboard.addEventListener(type, (e) => debug(type, { data: e.data, inputType: e.inputType, value: keyboard.value }), true);
  }
  for (const type of ['click', 'pointerdown']) {
    document.addEventListener(type, (e) => debug(type, { x: e.clientX, y: e.clientY, target: target(e) }), true);
  }
  addEventListener('error', (e) => debug('error', { message: e.message }));
  debug('start', {
    ua: navigator.userAgent,
    vkb: ['Hisense_enableVKB', 'Hisense_disableVKB', 'Hisense_SetRemoteKeyboard'].filter((n) => typeof window[n] === 'function'),
  });
}

let ex, u8, u32;
let cols, rows, cw, ch, ox, oy, font, boldFont, perCell, lastFont;
let lastCursorRow = -1, lastCursorX = -1;

function views() {
  if (!u8 || u8.buffer !== ex.memory.buffer) {
    u8 = new Uint8Array(ex.memory.buffer);
    u32 = new Uint32Array(ex.memory.buffer);
  }
}

async function fetchOk(url) {
  const res = await fetch(url);
  // The optional machines are only on servers that built them; the public site never has ?claude.
  if (res.status === 404 && VARIANT) {
    throw new Error(`?${VARIANT} is not available on this site (${url} is missing).\n` + (VARIANT === 'claude'
      ? 'Claude Code is proprietary, so that machine is not published:\nbuild it for your own use with zig build -Dclaude and serve it yourself.'
      : 'Build it with zig build -Dnode.'));
  }
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res;
}

// The compressed snapshot is handed to the wasm, which inflates it itself (no DecompressionStream
// needed, so older TV engines work) and keeps it for reboots.
function loadSnapshot(bytes) {
  const ptr = ex.snapshot_buffer(bytes.length);
  if (!ptr) throw new Error('Not enough memory for the Linux snapshot.');
  views();
  u8.set(bytes, ptr);
}

// Puts the machine back exactly as the snapshot tool left it: at a shell prompt. The fresh random
// bytes become the 64-bit guest's new VM generation ID, which makes Linux reseed its random number
// generator, so each session gets its own random numbers rather than the snapshot's.
function restore() {
  views();
  if (window.crypto && crypto.getRandomValues) crypto.getRandomValues(u8.subarray(ex.entropy_ptr(), ex.entropy_ptr() + 64));
  const status = ex.restore_snapshot();
  if (status === 2) throw new Error('The snapshot does not match this emulator build. Rebuild with zig build.');
  if (status !== 0) throw new Error('The Linux snapshot is damaged.');
}

function layout() {
  cols = ex.vt_cols();
  rows = ex.vt_rows();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(innerWidth * dpr);
  canvas.height = Math.round(innerHeight * dpr);
  canvas.style.width = `${innerWidth}px`;
  canvas.style.height = `${innerHeight}px`;
  cw = Math.floor(canvas.width / cols);
  ch = Math.floor(canvas.height / rows);
  ox = Math.floor((canvas.width - cw * cols) / 2);
  oy = Math.floor((canvas.height - ch * rows) / 2);
  // The largest font whose advance fits a cell; letterSpacing pads it to exactly one cell.
  ctx.font = `100px ${FONT}`;
  const advance = ctx.measureText('M').width / 100;
  const size = Math.floor(Math.min(cw / advance, ch / 1.25));
  font = `${size}px ${FONT}`;
  boldFont = `bold ${font}`;
  perCell = !('letterSpacing' in ctx);
  if (!perCell) ctx.letterSpacing = `${cw - advance * size}px`;
  ctx.textBaseline = 'middle';
  lastFont = '';
  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  views();
  u8.fill(1, ex.vt_dirty(), ex.vt_dirty() + rows);
  lastCursorRow = -1;
}

function drawRun(y, x0, x1, style, cellBase, invert) {
  const fg = style & 0xff, bg = (style >> 8) & 0xff, attr = (style >> 16) & 0xff;
  let fgc = attr & FG_SET ? PALETTE[attr & BOLD && fg < 8 ? fg + 8 : fg] : FG;
  let bgc = attr & BG_SET ? PALETTE[bg] : BG;
  if (!(attr & REVERSE) !== !invert) [fgc, bgc] = [bgc, fgc];
  const px = ox + x0 * cw, py = oy + y * ch, width = (x1 - x0) * cw;
  if (bgc !== BG) {
    ctx.fillStyle = bgc;
    ctx.fillRect(px, py, width, ch);
  }
  let text = '';
  for (let x = x0; x < x1; x++) {
    const c = u32[cellBase + x * 2];
    text += c > 32 ? String.fromCodePoint(c) : ' ';
  }
  ctx.fillStyle = fgc;
  if (text.trim()) {
    const f = attr & BOLD ? boldFont : font;
    if (f !== lastFont) ctx.font = lastFont = f;
    ctx.globalAlpha = attr & DIM ? 0.6 : 1;
    if (perCell) {
      for (let i = 0; i < text.length; i++) if (text[i] !== ' ') ctx.fillText(text[i], px + i * cw, py + ch / 2);
    } else {
      ctx.fillText(text, px, py + ch / 2);
    }
    ctx.globalAlpha = 1;
  }
  if (attr & UNDERLINE) ctx.fillRect(px, py + ch - Math.max(1, ch >> 4), width, Math.max(1, ch >> 4));
}

function drawRow(y, cursorX) {
  const cellBase = (ex.vt_cells() >> 2) + y * ex.vt_stride() * 2;
  ctx.fillStyle = BG;
  ctx.fillRect(ox, oy + y * ch, cols * cw, ch);
  for (let x = 0; x < cols;) {
    const style = u32[cellBase + x * 2 + 1] & 0xffffff;
    let end = x + 1;
    while (end < cols && (u32[cellBase + end * 2 + 1] & 0xffffff) === style) end++;
    drawRun(y, x, end, style, cellBase, false);
    x = end;
  }
  if (cursorX >= 0) drawRun(y, cursorX, cursorX + 1, u32[cellBase + cursorX * 2 + 1] & 0xffffff, cellBase, true);
}

function render() {
  views();
  const dirty = ex.vt_dirty();
  const scroll = ex.vt_take_scroll();
  if (scroll >= rows) {
    u8.fill(1, dirty, dirty + rows);
  } else if (scroll > 0) {
    // Shift the existing pixels; the terminal already marked only the new rows dirty.
    const h = (rows - scroll) * ch;
    ctx.drawImage(canvas, ox, oy + scroll * ch, cols * cw, h, ox, oy, cols * cw, h);
    lastCursorRow -= scroll;
  }
  const cursor = ex.vt_cursor();
  const cx = cursor & 0xff, cy = (cursor >> 8) & 0xff, visible = (cursor >> 16) & 1;
  if (lastCursorRow >= 0) u8[dirty + lastCursorRow] = 1;
  if (visible && (cy !== lastCursorRow || cx !== lastCursorX)) u8[dirty + cy] = 1;
  for (let y = 0; y < rows; y++) {
    if (!u8[dirty + y]) continue;
    u8[dirty + y] = 0;
    drawRow(y, visible && y === cy ? cx : -1);
  }
  lastCursorRow = visible ? cy : -1;
  lastCursorX = cx;
}

// Run loop: busy guests get ~12 ms per animation frame; idle guests sleep until their next timer tick.
// idle_us() is a u32 but arrives as a signed i32, hence the >>> 0.
let lastTime = 0, carryUs = 0, debtUs = 0, scheduled = false, timer = 0, lastInput = -Infinity;
let chase = 0, outAtInput = 0;

function elapsedUs() {
  const now = performance.now();
  carryUs += (now - lastTime) * 1000;
  lastTime = now;
  const us = Math.min(Math.floor(carryUs), 100000);
  carryUs = Math.min(carryUs - us, 100000);
  const repay = Math.min(us, debtUs);
  debtUs -= repay;
  return us - repay;
}

function tick() {
  scheduled = false;
  timer = 0;
  const start = performance.now();
  let exit;
  do {
    feedInput();
    exit = ex.run(SLICE, elapsedUs());
    // The UART has no interrupt, so Linux reads input and sends output only from a 10 ms timer.
    // While input is waiting, and after a keystroke until the guest answers, jump guest time to
    // that timer instead of waiting. Keystroke jumps are repaid from later slices so the clock
    // stays true; jumps that feed a transfer (a curl reply) just move the guest clock ahead.
    while (exit === EXIT_IDLE && performance.now() - start < FRAME_MS) {
      feedInput();
      const waiting = ex.input_pending() > 0;
      if (!waiting && (chase <= 0 || ex.out_count() !== outAtInput)) {
        chase = 0;
        break;
      }
      const us = Math.max(ex.idle_us() >>> 0, 1);
      if (us > 1000000) break; // no timer armed soon
      if (chase > 0) {
        if (debtUs + us > MAX_DEBT_US) break;
        debtUs += us;
        chase--;
      }
      exit = ex.run(SLICE, us);
    }
  } while (exit === EXIT_BUDGET && performance.now() - start < FRAME_MS);
  if (exit > EXIT_IDLE) {
    restore(); // `poweroff` or `reboot` gives a fresh machine
    layout();
  }
  checkHost();
  render();
  const floor = performance.now() - lastInput < TYPING_MS ? 0 : IDLE_MIN_MS;
  const busy = exit !== EXIT_IDLE || inputQueue.length > 0 || ex.input_pending() > 0;
  schedule(busy ? 0 : Math.min(Math.max((ex.idle_us() >>> 0) / 1000, floor), IDLE_MAX_MS));
}

function schedule(ms) {
  if (scheduled) return;
  scheduled = true;
  if (ms < 1) requestAnimationFrame(tick);
  else timer = setTimeout(tick, ms);
}

function wake() {
  if (timer) {
    clearTimeout(timer);
    timer = 0;
    scheduled = false;
  }
  schedule(0);
}

// Input: keys become the bytes a VT100 sends.
const encoder = new TextEncoder();
const KEYS = {
  Enter: '\r', Backspace: '\x7f', Tab: '\t', Escape: '\x1b', Delete: '\x1b[3~', Insert: '\x1b[2~',
  Home: '\x1b[H', End: '\x1b[F', PageUp: '\x1b[5~', PageDown: '\x1b[6~',
  F1: '\x1bOP', F2: '\x1bOQ', F3: '\x1bOR', F4: '\x1bOS', F5: '\x1b[15~', F6: '\x1b[17~',
  F7: '\x1b[18~', F8: '\x1b[19~', F9: '\x1b[20~', F10: '\x1b[21~', F11: '\x1b[23~', F12: '\x1b[24~',
};
const ARROWS = { ArrowUp: 'A', ArrowDown: 'B', ArrowRight: 'C', ArrowLeft: 'D' };
// TV remote: colour keys (HbbTV key codes) and Back.
const REMOTE = { 403: '\x03', 404: '\t', 405: '\x1b', 8: '\x7f', 461: '\x7f' };
const REMOTE_BLUE = 406;

// Bytes waiting for the guest's UART, fed in as its 4 KB ring drains (a curl reply can be MBs).
const inputQueue = [];
let inputOffset = 0;

function feedInput() {
  views();
  while (inputQueue.length) {
    const free = ex.input_free();
    if (!free) return;
    const chunk = inputQueue[0];
    const n = Math.min(free, 256, chunk.length - inputOffset);
    u8.set(chunk.subarray(inputOffset, inputOffset + n), ex.input_ptr());
    ex.push_input(n);
    inputOffset += n;
    if (inputOffset === chunk.length) {
      inputQueue.shift();
      inputOffset = 0;
    }
  }
}

function send(text) {
  if (host.busy) {
    // A host request owns the console until its reply is queued; Ctrl-C cancels it.
    if (text === '\x03' && host.abort) host.abort.abort();
    else host.held.push(text);
    return;
  }
  inputQueue.push(encoder.encode(text));
  feedInput();
  lastInput = performance.now();
  chase = CHASE_TICKS;
  outAtInput = ex.out_count();
  wake();
}

// Host services. The guest has no network card, so guest/curl writes a request frame to the
// console (see hostFilter in src/wasm.zig): uuencode -m text of "<service>\n<method>\n<url>\n
// <header lines>\n\n<body>". The page performs it and types back, as raw bytes,
// "<code> <text>\n<n>\n<n bytes of headers><n>\n<n bytes of body>"; code 0 means it failed.
const host = { busy: false, abort: null, held: [] };
const MAX_REPLY = 16 << 20; // the guest has 64 MB of RAM in all

function checkHost() {
  const len = ex.host_request_len();
  if (!len || host.busy) return;
  views();
  const frame = new TextDecoder().decode(u8.subarray(ex.host_request_ptr(), ex.host_request_ptr() + len));
  ex.host_request_done();
  host.busy = true;
  hostRequest(frame).then(
    (r) => hostReply(r.code, r.text, r.head, r.body),
    (err) => hostReply(0, err && err.name === 'AbortError' ? 'interrupted' : hostError(err), new Uint8Array(0), new Uint8Array(0)),
  );
}

function hostError(err) {
  return err && err.message ? err.message : String(err);
}

// Browsers send a preflight (an OPTIONS request the server must approve) before any cross-origin
// request with a method or header outside the CORS "simple" set. Returns what triggered it, if anything.
const SIMPLE_TYPES = ['application/x-www-form-urlencoded', 'multipart/form-data', 'text/plain'];
function preflightCause(method, headers) {
  if (method !== 'GET' && method !== 'HEAD' && method !== 'POST') return `the ${method} method`;
  let cause = '';
  headers.forEach((value, name) => {
    if (cause || name === 'accept' || name === 'accept-language' || name === 'content-language') return;
    if (name === 'content-type' && SIMPLE_TYPES.includes(value.split(';')[0].trim().toLowerCase())) return;
    cause = `the ${name} header`;
  });
  return cause;
}

async function hostRequest(frame) {
  // uuencode -m wraps base64 in "begin-base64 644 -" and "====" lines.
  const b64 = frame.split('\n').filter((l) => l && !l.startsWith('begin-base64') && l !== '====').join('');
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  let sep = 0;
  while (sep + 1 < bytes.length && !(bytes[sep] === 10 && bytes[sep + 1] === 10)) sep++;
  const lines = new TextDecoder().decode(bytes.subarray(0, sep)).split('\n');
  const body = bytes.subarray(sep + 2);
  const [service, method, url] = lines;
  debug('host', { service, method, url, body: body.length });
  if (service !== 'curl') throw new Error(`unknown host service ${service}`);

  const init = { method, headers: new Headers(), redirect: 'follow', cache: 'no-store' };
  for (const line of lines.slice(3)) {
    const colon = line.indexOf(':');
    if (colon <= 0) continue;
    try {
      init.headers.append(line.slice(0, colon).trim(), line.slice(colon + 1).trim());
    } catch (err) {
      // Not a valid header name or value for this browser: curl would send it, we cannot.
    }
  }
  if (method !== 'GET' && method !== 'HEAD') init.body = body;
  if (typeof AbortController === 'function') {
    host.abort = new AbortController();
    init.signal = host.abort.signal;
  }
  let res;
  try {
    res = await fetch(url, init);
  } catch (err) {
    if (err.name === 'AbortError') throw err;
    const cause = new URL(url, location.href).origin === location.origin ? '' : preflightCause(method, init.headers);
    throw new Error(cause
      ? `blocked by the browser: ${cause} needs a CORS preflight, and ${new URL(url).host} did not allow it`
      : `could not fetch ${url}: the site is unreachable or does not allow cross-origin requests`);
  }
  const data = method === 'HEAD' ? new Uint8Array(0) : new Uint8Array(await res.arrayBuffer());
  if (data.length > MAX_REPLY) throw new Error(`the response is ${(data.length / 1048576).toFixed(1)} MB, too large for the emulated machine`);
  let head = `HTTP/1.1 ${res.status} ${res.statusText}\r\n`;
  res.headers.forEach((value, name) => {
    head += `${name}: ${value}\r\n`;
  });
  return { code: res.status, text: res.statusText || 'OK', head: encoder.encode(`${head}\r\n`), body: data };
}

function hostReply(code, text, head, body) {
  inputQueue.push(encoder.encode(`${code} ${text.replace(/\n/g, ' ')}\n${head.length}\n`), head,
    encoder.encode(`${body.length}\n`), body);
  host.busy = false;
  host.abort = null;
  for (const keys of host.held.splice(0)) inputQueue.push(encoder.encode(keys));
  wake();
}

function openKeyboard() {
  keyboard.style.display = 'block';
  let vkb;
  if (typeof window.Hisense_enableVKB === 'function') {
    try {
      vkb = window.Hisense_enableVKB();
    } catch (err) {
      vkb = `threw ${err.message}`;
    }
  }
  keyboard.focus();
  debug('openKeyboard', { vkb: String(vkb), focused: document.activeElement === keyboard });
}

function toggleKeyboard() {
  if (document.activeElement === keyboard) keyboard.blur();
  else openKeyboard();
}

// VIDAA's on-screen keyboard keeps its own copy of the text and rewrites the whole field on every
// change: "l", then "ls", then "l" after Backspace (which sends no key event). So the guest gets
// only the difference from what it already has: DELs back to the common prefix, then the new tail.
let barText = [];

function syncBar() {
  const now = Array.from(keyboard.value);
  let same = 0;
  while (same < now.length && same < barText.length && now[same] === barText[same]) same++;
  const edit = '\x7f'.repeat(barText.length - same) + now.slice(same).join('');
  barText = now;
  if (edit) send(edit);
}

function closeBar() {
  keyboard.value = '';
  barText = [];
  keyboard.style.display = 'none';
  keyboard.blur();
}

function onKey(e) {
  if (e.keyCode === REMOTE_BLUE) {
    e.preventDefault();
    toggleKeyboard();
    return;
  }
  if (e.target === keyboard && e.key === 'Enter') {
    // The on-screen keyboard's Enter: deliver its last edit, then the line; the next line starts fresh.
    e.preventDefault();
    syncBar();
    send('\r');
    closeBar();
    return;
  }
  let s = null;
  if (e.key in ARROWS) {
    s = (ex.vt_app_cursor() ? '\x1bO' : '\x1b[') + ARROWS[e.key];
  } else if (e.ctrlKey && e.key.length === 1) {
    const c = e.key.toUpperCase().charCodeAt(0);
    if (c >= 64 && c < 96) s = String.fromCharCode(c - 64);
    else if (e.key === ' ') s = '\0';
  } else if (e.key in KEYS) {
    s = KEYS[e.key];
  } else if (e.keyCode in REMOTE) {
    s = REMOTE[e.keyCode];
  } else if (e.key.length === 1 && !e.metaKey) {
    s = e.key;
  }
  if (s === null) return; // e.g. "Process" from an input method: the input event carries the text
  if (e.altKey && !e.ctrlKey && s.length === 1) s = `\x1b${s}`;
  e.preventDefault();
  send(s);
}

async function main() {
  const [wasm, snap] = await Promise.all([
    fetchOk(WASM).then((r) => r.arrayBuffer()).then((b) => WebAssembly.instantiate(b, {})),
    fetchOk(SNAPSHOT).then((r) => r.arrayBuffer()),
  ]);
  ex = wasm.instance.exports;
  loadSnapshot(new Uint8Array(snap));
  restore();
  layout();
  statusEl.remove();
  document.addEventListener('keydown', onKey);
  document.addEventListener('paste', (e) => {
    e.preventDefault();
    send(e.clipboardData.getData('text').replace(/\r?\n/g, '\r'));
  });
  keyboard.addEventListener('input', syncBar);
  keyboard.addEventListener('change', syncBar);
  keyboard.addEventListener('blur', closeBar);
  // In the TV's Browser app the remote drives a pointer and OK is a click.
  canvas.addEventListener('click', openKeyboard);
  addEventListener('resize', () => {
    layout();
    render();
  });
  lastTime = performance.now();
  render();
  schedule(0);
}

main().catch((err) => {
  statusEl.textContent = `rvterm failed to start:\n${err.message}`;
  console.error(err);
});
