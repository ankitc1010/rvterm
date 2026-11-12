// Boots the 32-bit no-MMU Linux in the wasm emulator and saves the machine at a shell prompt, so
// the page starts instantly instead of booting. See snapshot.mjs for the format.
// Usage: node mksnapshot.mjs <rvterm.wasm> <kernel Image> <dtb> <out snapshot.bin.gz> [guest files...]
// Guest files (guest/curl, guest/bash, ...) are installed into /bin, so #!/bin/bash scripts work.

import { readFileSync } from 'node:fs';
import { COLS, Guest, ROWS, banner, loadWasm, writeSnapshot } from './snapshot.mjs';

const [wasmPath, kernelPath, dtbPath, outPath, ...guestFiles] = process.argv.slice(2);
if (!outPath) {
  console.error('usage: node mksnapshot.mjs <rvterm.wasm> <Image> <dtb> <out.bin.gz> [guest files...]');
  process.exit(2);
}

const ex = await loadWasm(wasmPath);
const guest = new Guest(ex);
ex.reset(COLS, ROWS);
guest.mem().set(readFileSync(kernelPath), ex.ram_ptr());
guest.mem().set(readFileSync(dtbPath), ex.ram_ptr() + ex.dtb_offset());

guest.runUntil(/login: $/, 'the login prompt');
guest.command('root', /# $/, 'the shell prompt');
// On no-MMU, hush re-executes itself for every $(...) under its own argv[0]. As the login shell
// ("-sh") each child re-reads /etc/profile, whose `id -u` test recurses until RAM runs out.
// A plain non-login shell avoids that; the profile's exports are inherited.
guest.command('exec sh', /# $/, 'the non-login shell');
// The console comes up with -icrnl, so Enter (sent as CR) would not end lines for programs like cat.
// The UART has no interrupt, so Linux polls it; at 9600 baud with a 128-byte FIFO that is every
// ~50 ms, at 115200 every 10 ms tick, which is what makes typing feel immediate.
const size = guest.command(`stty rows ${ROWS} cols ${COLS} icrnl 115200; stty size`, /# $/, 'stty');
if (!size.includes(`${ROWS} ${COLS}`)) throw new Error(`stty did not take effect:\n${size}`);
guest.install(guestFiles, '/bin', /# $/);
guest.command(banner('Linux $(uname -r)'), /# $/, 'the banner');
guest.settle();
writeSnapshot(ex, outPath);
