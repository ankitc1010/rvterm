// Boots 64-bit Alpine Linux in the wasm emulator and saves the machine at a shell prompt, so the
// page starts instantly instead of booting (about 450M instructions). See snapshot.mjs for the format.
// Usage: node mksnapshot64.mjs <rvterm64.wasm> <kernel Image> <initrd.cpio.gz> <out snapshot64.bin.gz> [guest files...]
// Guest files (guest/curl, guest/bash, ...) are installed into /usr/local/bin.

import { randomFillSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { COLS, Guest, ROWS, banner, loadWasm, writeSnapshot } from './snapshot.mjs';

const [wasmPath, kernelPath, initrdPath, outPath, ...guestFiles] = process.argv.slice(2);
if (!outPath) {
  console.error('usage: node mksnapshot64.mjs <rvterm64.wasm> <Image> <initrd.cpio.gz> <out.bin.gz> [guest files...]');
  process.exit(2);
}

const ex = await loadWasm(wasmPath);
const guest = new Guest(ex);
const kernel = readFileSync(kernelPath);
const initrd = readFileSync(initrdPath);
ex.reset(COLS, ROWS);
guest.mem().set(kernel, ex.ram_ptr() + ex.kernel_offset());
guest.mem().set(initrd, ex.ram_ptr() + ex.initrd_offset(initrd.length));
randomFillSync(guest.mem().subarray(ex.entropy_ptr(), ex.entropy_ptr() + 64)); // seeds the guest's RNG
ex.boot_linux(initrd.length);

// Alpine's ash asks the terminal for the cursor position (ESC [ 6 n) right after each prompt.
const prompt = /rvterm:[^\n]*# (\x1b\[6n)?$/;
guest.runUntil(prompt, 'the shell prompt');
const size = guest.command(`stty rows ${ROWS} cols ${COLS}; stty size`, prompt, 'stty');
if (!size.includes(`${ROWS} ${COLS}`)) throw new Error(`stty did not take effect:\n${size}`);
guest.install(guestFiles, '/usr/local/bin', prompt);
guest.command(banner('Alpine Linux $(cat /etc/alpine-release), kernel $(uname -r), RV64GC$([ -x /usr/bin/node ] && echo ", with Node.js")'), prompt, 'the banner');
guest.settle();
writeSnapshot(ex, outPath);
