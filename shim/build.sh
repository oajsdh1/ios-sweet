#!/bin/bash
# Build the shim and wrap it in a boot.img v1 header (perseus ABL, 2018 Pie-era,
# has no v2 DTB support; the hackios UEFI images booted on a real MIX 3 through
# exactly this shape: v1, default base/offsets, pagesize 2048, no dtb field).
# The shim only reads /chosen linux,initrd-* from whatever FDT the ABL hands it.
set -euo pipefail
cd "$(dirname "$0")"
CC=aarch64-linux-gnu-gcc
OBJCOPY=aarch64-linux-gnu-objcopy
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$(aarch64-linux-gnu-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
# Portable: nm prints _end as hex; convert with bash arithmetic (no gawk strtonum).
size=$(aarch64-linux-gnu-nm out/shim.elf | awk '$3=="_end"{print $1}')
size=$((16#${size:-0}))
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
# perseus ABL (MIUI, Android 10 firmware) only hands off when the kernel field
# carries the device DTB: gzipped Image with the stock perseus.dtb appended
# after the gzip stream (the MIUI convention - without it the boot path bails
# silently: black screen, no jump). ramdisk: the ABL takes a 5-byte stub fine.
gzip -9 -c out/Image > out/Image.gz
cat out/Image.gz ../dtb/perseus.dtb > out/kernel.gz.dtb
# Vendored AOSP mkbootimg (tools/mkbootimg.py): Ubuntu 24.04's packaged
# mkbootimg imports a gki module that ships broken. Override with MKBOOTIMG=...
# if you have a working one on PATH.
MKBOOTIMG=${MKBOOTIMG:-../tools/mkbootimg.py}
python3 "$MKBOOTIMG" --header_version 1 --kernel out/kernel.gz.dtb --ramdisk ../dtb/ramdisk.stub \
	--pagesize 2048 -o out/shim-boot.img
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
