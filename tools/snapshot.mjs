// Shared by mksnapshot.mjs (32-bit) and mksnapshot64.mjs (64-bit Alpine): drives a guest in the
// same wasm the page uses, then saves the machine sitting at a shell prompt.
//
// Snapshot format (gzipped): "RVSNAP03", u32 machine_len, u32 ram_len, u32 unique_count,
// u32 map_count, the machine bytes, map_count records of u32 page index + u32 unique page number
// (sorted by unique page), then unique_count distinct 4096-byte pages. Zero pages are omitted, and
// each distinct page is stored once (freed RAM holds many stale copies of the same pages). The map
// comes first so src/wasm.zig can inflate each page straight into RAM.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import { gzipSync } from 'node:zlib';

export const COLS = 100;
export const ROWS = 30;
const PAGE = 4096;

export class Guest {
  constructor(ex) {
    this.ex = ex;
    this.output = '';
    this.elapsed = 0;
  }

  mem() {
    return new Uint8Array(this.ex.memory.buffer);
  }

  // Virtual clock: busy slices count as 10 ms, idle time jumps straight to the next timer tick.
  step() {
    const exit = this.ex.run(1_000_000, this.elapsed);
    this.elapsed = exit === 1 ? Math.min(Math.max(this.ex.idle_us() >>> 0, 1), 1_000_000) : 10_000;
    const len = this.ex.log_len();
    if (len) {
      this.output += Buffer.from(this.mem().subarray(this.ex.log_ptr(), this.ex.log_ptr() + len)).toString('latin1');
      this.ex.log_clear();
    }
    return exit;
  }

  runUntil(pattern, what, maxInstructions = 6e9) {
    const limit = this.ex.instret() + maxInstructions;
    while (this.ex.instret() < limit) {
      if (this.step() >= 2) throw new Error(`guest powered off while waiting for ${what}`);
      if (pattern.test(this.output)) return;
    }
    throw new Error(`timed out waiting for ${what}; output so far:\n${this.output.slice(-2000)}`);
  }

  // Types text into the console, waiting for the guest to drain its 4 KB input ring as it goes.
  type(text) {
    this.output = '';
    const bytes = Buffer.from(text, 'utf8');
    for (let i = 0; i < bytes.length;) {
      const n = Math.min(256, this.ex.input_free(), bytes.length - i); // the staging buffer holds 256 bytes
      if (n === 0) {
        this.step();
        continue;
      }
      this.mem().set(bytes.subarray(i, i + n), this.ex.input_ptr());
      this.ex.push_input(n);
      i += n;
    }
  }

  // Runs a command and waits for the prompt to come back.
  command(text, prompt, what) {
    this.type(`${text}\n`);
    this.runUntil(prompt, what ?? text);
    return this.output;
  }

  // Guest programs travel as uuencode -m text in a heredoc, which survives the shell's line editor.
  install(files, dir, prompt) {
    for (const file of files) {
      const name = basename(file);
      const b64 = readFileSync(file).toString('base64').match(/.{1,60}/g).join('\n');
      // One command (the heredoc body follows its first line), so the prompt only returns at the end.
      const out = this.command(`uudecode -o ${dir}/${name} <<'EOF' && chmod 755 ${dir}/${name} && echo "installed:${name}"\n` +
        `begin-base64 755 ${name}\n${b64}\n====\nEOF`, prompt, `installing ${name}`);
      // bash prints \e[?2004l\r (end of bracketed paste) before command output, so accept \r or \n.
      if (!new RegExp(`[\\r\\n]installed:${name}`).test(out)) throw new Error(`${name} did not install:\n${out.slice(-1500)}`);
    }
  }

  // Lets the shell settle into its blocking read.
  settle() {
    for (let i = 0; i < 50; i++) this.step();
    this.ex.log_clear();
  }
}

export async function loadWasm(path) {
  const { instance } = await WebAssembly.instantiate(readFileSync(path), {});
  return instance.exports;
}

export function writeSnapshot(ex, outPath) {
  const mem = new Uint8Array(ex.memory.buffer);
  const machineLen = ex.machine_len();
  const ramLen = ex.ram_len() >>> 0;
  const ram = mem.subarray(ex.ram_ptr(), ex.ram_ptr() + ramLen);
  const unique = [];
  const byHash = new Map();
  const map = [];
  for (let i = 0; i < ramLen / PAGE; i++) {
    const page = ram.subarray(i * PAGE, (i + 1) * PAGE);
    if (!page.some((b) => b !== 0)) continue;
    const hash = createHash('sha1').update(page).digest('hex');
    if (!byHash.has(hash)) {
      byHash.set(hash, unique.length);
      unique.push(page);
    }
    map.push([i, byHash.get(hash)]);
  }

  map.sort((a, b) => a[1] - b[1] || a[0] - b[0]);
  const out = Buffer.alloc(24 + machineLen + map.length * 8 + unique.length * PAGE);
  out.write('RVSNAP03', 0, 'latin1');
  out.writeUInt32LE(machineLen, 8);
  out.writeUInt32LE(ramLen, 12);
  out.writeUInt32LE(unique.length, 16);
  out.writeUInt32LE(map.length, 20);
  out.set(mem.subarray(ex.machine_ptr(), ex.machine_ptr() + machineLen), 24);
  let off = 24 + machineLen;
  for (const [index, id] of map) {
    out.writeUInt32LE(index, off);
    out.writeUInt32LE(id, off + 4);
    off += 8;
  }
  for (const page of unique) {
    out.set(page, off);
    off += PAGE;
  }
  const gz = gzipSync(out, { level: 9 });
  writeFileSync(outPath, gz);
  console.log(`snapshot: ${(ex.instret() / 1e6).toFixed(0)}M instructions to boot, ${map.length} pages in use, ` +
    `${unique.length} distinct (${(out.length / 1048576).toFixed(1)} MB), ${(gz.length / 1048576).toFixed(2)} MB gzipped`);
}

export function banner(kind) {
  return 'clear; printf \'\\033[1;36mrvterm\\033[0m  %s on an emulated RISC-V CPU (Zig + WebAssembly)\\n' +
    '\\033[2mRemote: blue (or OK in the Browser app) opens the keyboard; red Ctrl-C, green Tab, yellow Esc. ' +
    `Type reboot for a fresh machine.\\033[0m\\n\\n' "${kind}"`;
}
