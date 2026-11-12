#!/bin/sh
# Builds the official riscv-tests (RV64 user, supervisor and machine suites, in both the physical
# "p" and virtual-memory "v" environments) with zig cc, and runs them on the RV64 core.
# Usage: tools/riscv-tests.sh [work dir]   (from the project root; default work dir /tmp/riscv-tests)
set -eu
root=$(pwd)
work=${1:-/tmp/riscv-tests}
zig build -Doptimize=ReleaseSafe >/dev/null
if [ ! -d "$work" ]; then
    git clone -q --depth 1 https://github.com/riscv-software-src/riscv-tests.git "$work"
    git clone -q --depth 1 https://github.com/riscv/riscv-test-env.git "$work/env"
fi
cd "$work"
mkdir -p out out/sysinc
# lld does not accept GNU ld's SHF_* names in PHDRS FLAGS.
sed 's/FLAGS(SHF_ALLOC | SHF_EXECINSTR)/FLAGS(7)/' env/p/link.ld > out/link-p.ld
sed 's/FLAGS(SHF_ALLOC | SHF_EXECINSTR)/FLAGS(7)/' env/v/link.ld > out/link-v.ld
# env/v's C code wants a few libc headers; it brings its own implementations.
cat > out/sysinc/string.h <<'EOF'
#pragma once
#include <stddef.h>
void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
char *strcpy(char *dst, const char *src);
EOF
printf '#pragma once\n' > out/sysinc/ctype.h
printf '#pragma once\n#include <stddef.h>\n#include <stdarg.h>\n' > out/sysinc/stdio.h

cpu_for() {
    case $1 in rv64uc) echo generic_rv64+m+a+f+d+c+zicsr+zifencei ;; *) echo generic_rv64+m+a+f+d+zicsr+zifencei ;; esac
}
built=0
for suite in rv64ui rv64um rv64ua rv64uc rv64uf rv64ud rv64si rv64mi; do
    cpu=$(cpu_for $suite)
    for src in isa/$suite/*.S; do
        name=$(basename "$src" .S)
        # clang rejects .weak followed by .global, so drop .weak for handlers a test defines.
        inc=out/inc-$suite-$name
        mkdir -p "$inc"
        cp env/p/riscv_test.h "$inc/"
        pre=$(zig cc -target riscv64-freestanding -mcpu=$cpu -E -I env/p -I isa/macros/scalar "$src" 2>/dev/null)
        for hnd in mtvec_handler stvec_handler; do
            if printf '%s\n' "$pre" | grep -q "$hnd:"; then sed -i "s/\.weak $hnd;//" "$inc/riscv_test.h"; fi
        done
        zig cc -target riscv64-freestanding -mcpu=$cpu -mcmodel=medany -nostdlib -static -I "$inc" -I env/p \
            -I isa/macros/scalar -T out/link-p.ld "$src" -o "out/$suite-p-$name" && built=$((built + 1))
        case $suite in rv64si|rv64mi) continue ;; esac
        entropy=$(echo "$suite-v-$name" | md5sum | cut -c 1-7)
        zig cc -target riscv64-freestanding -mcpu=$cpu -mcmodel=medany -nostdlib -static -std=gnu99 -O2 -fno-builtin \
            -DENTROPY=0x$entropy -I out/sysinc -I env/v -I isa/macros/scalar -T out/link-v.ld env/v/entry.S env/v/*.c \
            "$src" -o "out/$suite-v-$name" && built=$((built + 1))
    done
done
echo "built $built tests"
"$root/zig-out/bin/rvtest64" $(ls out/rv64*-[pv]-* | grep -v '\.') > out/results.txt || true
echo "passed $(grep -c '^PASS' out/results.txt) of $(wc -l < out/results.txt)"
grep -v '^PASS' out/results.txt || true
