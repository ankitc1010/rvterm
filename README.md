# rvterm

An offline Linux terminal with Node.js for Linux-based TVs and devices whose apps are web apps:
Hisense VIDAA, Samsung Tizen, LG webOS, Android TV (through a WebView), and any browser. A RISC-V
CPU emulator, a VT100 terminal and a gzip decoder, all written in Zig, compile to WebAssembly. They
run real Linux, restored from a snapshot, so the page opens straight at a shell prompt. Nothing
connects to the network once the page has loaded.

The machine:

| | |
|---|---|
| CPU | RV64GC (IMAFDC, Zicsr, Zifencei, Sstc), M/S/U modes, Sv39 MMU |
| Linux | Alpine 3.24.3, kernel 6.18 LTS, bash, GNU coreutils and grep, BusyBox, `apk` |
| Node.js | Alpine's Node.js 24 |
| Devices | 16550 UART with interrupts, PLIC, VM generation ID, built-in SBI |
| wasm / snapshot | 67 KB / 41 MB |
| RAM / speed in Chrome | 256 MB / about 33 MIPS |

Each `node` start runs about 210M instructions, about 5 s at full speed (Node.js running the wasm)
and longer on a TV. Node has no network: `require('https')` cannot reach anything, but `curl` can
(see below). nvm installs, but cannot download a Node for riscv64 musl; `nvm use system` picks the
built-in one. GNU coreutils and grep are there for scripts such as nvm that expect them.

## Layout

| Path | What |
|---|---|
| `src/rv64.zig` | RV64GC hart: integer, atomics, F/D floating point, compressed, privileged modes, Sv39 with a translation cache, SBI |
| `src/machine64.zig` | The machine: 16550 UART, PLIC, VM generation ID, device tree builder, boot layout |
| `src/vt.zig` | VT100/xterm-subset terminal: escape parser and cell grid, with dirty rows and scroll hints |
| `src/wasm.zig` | WebAssembly exports and snapshot restore; guest output goes into the terminal without crossing into JS |
| `src/inflate.zig` | Small gzip decoder (puff-style), about 6 KB of wasm versus about 45 KB for `std.compress.flate` |
| `src/native64.zig` | Native runner that boots the machine in your terminal, for debugging and benchmarks |
| `src/rvtest.zig` | Runs riscv-tests ELF binaries on the RV64 core |
| `web/` | `index.html` + `term.js`: canvas renderer, run loop, keyboard and TV remote input, the `curl` bridge |
| `tools/snapshot.mjs`, `tools/mksnapshot64.mjs` | Boot Linux in Node with the same wasm, install `guest/` programs and save the machine at the prompt |
| `tools/mkinitrd.py` | Turns Alpine's minirootfs tarball into the initramfs, with `/init` and direct `poweroff` |
| `tools/fetch-alpine.sh` | Downloads Alpine's riscv64 kernel and minirootfs and builds `linux64/` |
| `tools/alpine-packages.py`, `tools/npm-package.py` | Fetch Alpine packages (with dependencies) and npm packages for the initramfs, checking their checksums |
| `tools/riscv-tests.sh` | Builds the official riscv-tests with `zig cc` and runs them on the RV64 core |
| `guest/curl` | `curl` for the guest: a shell script that hands requests to the page (see below) |
| `linux64/` | Alpine's kernel `Image` and the initramfs (made by `tools/fetch-alpine.sh`, not in the repository) |
| `serve.py` | LAN server for the TV: the terminal at `/`, the capability probe at `/probe/` |
| `tools/deploy-pages.sh` | Builds the site and publishes it to GitHub Pages (see below) |
| `probe/` | Capability probe page used to check the TV's browser engine |

## Build and run

Needs Zig 0.17, Node (for the snapshot step) and Python 3.

```sh
tools/fetch-alpine.sh  # once: linux64/Image and linux64/initrd.cpio.gz
zig build              # zig-out/web: rvterm64.wasm, snapshot64.bin.gz, index.html, term.js
zig build test         # terminal and decoder unit tests
tools/riscv-tests.sh   # RV64 core against the official riscv-tests: 244 of 244 pass
zig build run          # boot Alpine natively in this terminal (Ctrl-] quits)
python3 serve.py       # then open http://<this machine>:8080/
```

`tools/fetch-alpine.sh` bakes bash, coreutils, grep and nodejs into the initramfs. Name other
Alpine packages to replace that list; `npm:name@version` adds a package from the npm registry.

The snapshot stores the emulator's state structs as raw bytes, so it is rebuilt whenever the wasm
changes. `zig build` takes care of that.

## GitHub Pages

`tools/deploy-pages.sh` runs `zig build` and publishes the site to the `gh-pages` branch as a
single fresh commit, so the large snapshot doesn't accumulate in the history. GitHub Pages serves
that branch.

Over HTTPS the browser blocks requests to plain `http://` URLs (mixed content), so `curl` there
only reaches `https://` sites. Use `serve.py` on the LAN for `http://` targets.

## Keys

Keyboard input is sent as VT100 bytes. On the TV remote: red is Ctrl-C, green is Tab, yellow is
Esc, and Back is Backspace. The blue key opens a typing bar at the bottom of the screen. In the
Browser app, where the remote drives a pointer, OK opens it instead. The TV's on-screen keyboard
attaches to that bar, and each character goes straight to the terminal. Typing `reboot` or
`poweroff` gives you a fresh machine.

Open the page with `?debug` to have every key, focus and input event sent to `serve.py`. They land
in `probe/reports/log-<tv-ip>.jsonl`. This shows what a given TV's remote and on-screen keyboard
actually deliver.

## curl

The emulated machine has no network card, so `curl` (a shell script in `guest/`) hands each
request to the page:

1. It sets the console to raw mode and writes the request as `ESC ] 7777 ; <uuencode -m> BEL`.
2. `hostFilter` in `src/wasm.zig` keeps that frame off the screen. `term.js` runs it with the
   browser's `fetch()`.
3. The page types back `<code> <text>\n<n>\n<headers><n>\n<body>` as raw bytes. Your own
   keystrokes are held until the reply is queued, and Ctrl-C cancels a request.
4. The script reads the reply with `dd iflag=fullblock,count_bytes`, so it gets exact byte counts.
   (`head -c` reads ahead.)

Supported options: `-d/--data` (`@file` too), `-f`, `-H`, `-i`, `-I`, `-o`/`-o-`, `-O`, `-s`, `-u`,
`-v`, `-w '%{http_code}'`, `-X` and `-A`. `-L`, `-S`, `-k` and `--compressed` are accepted and ignored.

Limits:
- **Cross-origin rules apply.** A browser page can only read sites that allow cross-origin requests
  (CORS). Requests that need a preflight (an `Authorization` header, a JSON `Content-Type`, `PUT`
  and so on) also need the server to approve it. Other requests fail with `curl: (7)`, naming what
  triggered the preflight. Packaged apps (Tizen, webOS, Android TV) may be allowed more.
- **Speed.** Replies travel over the emulated serial port, so large downloads are slow, and slower
  still on a TV. A virtio device would be faster.
- **Size.** Replies are capped at 16 MB.

## Portability

- **WebAssembly MVP only.** Zig's default wasm CPU enables post-MVP features (multivalue,
  sign-ext, bulk memory, extended-const) that 2019–2021 TV engines (Chromium 63–85) reject. The
  build pins `cpu.mvp`; speed is unchanged.
- **No DecompressionStream.** The snapshot is decompressed inside the wasm, because that API only
  exists from Chromium 80.
- **Minimum engine:** WebAssembly MVP and async/await, so roughly Chromium 57 (Samsung 2020+, LG
  webOS 5+, VIDAA, any Android TV WebView). This has not been tested on an old engine yet.
- **Memory:** about 300 MB of linear memory (256 MB guest RAM plus the 41 MB snapshot). The test TV
  allowed about 450 MB.

## Notes on the machine

- **No firmware.** The kernel starts in S-mode; `rv64.zig` answers its SBI calls itself (base,
  TIME, IPI, RFENCE, HSM, SRST and the legacy console). The timer is Sstc (`stimecmp`).
- **Sv39 only.** The kernel probes Sv57 and Sv48 by writing `satp` and reading it back; unsupported
  modes leave `satp` unchanged, so it falls back to Sv39. A/D bits are set by the hardware.
- **Interrupt-driven UART.** Keys raise a PLIC interrupt, so echo is immediate (4–17 ms in Chrome).
- **Snapshot size.** The kernel, Alpine's files and Node.js are about 100 MB of distinct pages,
  41 MB gzipped; boot to the prompt is about 2 billion instructions, which the TV never runs. Each
  distinct 4 KB page is stored once, and the page map comes before the pages, so each page is
  decompressed straight into RAM with only a 32 KB window.
- **Random numbers.** The machine has no entropy source of its own, and Linux's jitter fallback
  needs a finer clock than the microsecond timer, so `getrandom()` (Node, OpenSSL, Python) blocked
  forever. The host's random bytes go into the device tree's `rng-seed`, which seeds Linux at
  boot. Every copy of a snapshot would then replay the same "random" numbers, so each restore also
  gives the guest a new VM generation ID (`microsoft,vmgenid`, PLIC source 11). That makes Linux
  reseed (`crng reseeded due to virtual machine fork` in dmesg), the mechanism cloud VMs use.
- **poweroff.** There is no init daemon, so `/usr/local/sbin/poweroff` and `reboot` call the kernel
  directly (`busybox poweroff -f`).
- **Speed.** About 66 MIPS native and 33 MIPS in Chrome: each memory access goes through the
  translation cache, and compressed instructions are expanded every time. A decoded-instruction
  cache is the next step.
- **Idle cost.** While the guest idles, the page wakes at most every 30–100 ms. Linux catches up on
  the late timer ticks.

## Credits and licences

The machine runs Alpine Linux's own kernel and minirootfs (Linux is GPL-2.0; Alpine's packages,
Node.js among them, carry their own licences, with sources at alpinelinux.org). If you distribute
`linux64/` or the snapshot, you must also offer the corresponding source. The RV64 core is tested
with [riscv-tests](https://github.com/riscv-software-src/riscv-tests).
