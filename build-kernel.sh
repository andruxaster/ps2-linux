#!/usr/bin/env bash
# Ядро frno7/linux + IOP-прошивки + initramfs, который загружает USB,
# находит ext4-раздел флешки и делает switch_root.
#
#   ./build-kernel.sh                       # → out/VMLINUZ.ELF, out/modules/
#   PROFILE=stock ./build-kernel.sh         # ps2_defconfig без изменений
#   VIDEO=1920x1080i@60 ./build-kernel.sh   # режим по умолчанию (меняется и на флешке)
#
# PROFILE=fast (по умолчанию) — ps2_defconfig плюс:
#   zram + LZ4 модулями (rcS включает zram-swap), без отладочных опций
#   (KALLSYMS_ALL, SLUB_DEBUG, PERF_EVENTS, DEBUG_FS, DEBUG_MEMORY_INIT, DEBUG_INFO),
#   HZ=100, PREEMPT_NONE. В initramfs в обоих профилях — только нужные модули.
#
set -euo pipefail

TARGET=${TARGET:-mipsr5900el-unknown-linux-musl}
PREFIX=${PREFIX:-$HOME/x-tools/mipsr5900el}
TOP=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$TOP/work}
OUT=${OUT:-$TOP/out}
JOBS=${JOBS:-$(nproc)}
# Компонентный кабель: HD-режимы GS выводит в YPbPr. 720p — читаемая консоль.
VIDEO=${VIDEO:-1280x720p@60}
PROFILE=${PROFILE:-fast}
case "$PROFILE" in fast|stock) ;; *) echo "PROFILE: fast или stock" >&2; exit 1;; esac
BUSYBOX_REF=${BUSYBOX_REF:-1_36_1}
LINUX_BRANCH=${LINUX_BRANCH:-ps2-main}

export PATH=$PREFIX/bin:$PATH
export ARCH=mips CROSS_COMPILE=$TARGET-
command -v $TARGET-gcc >/dev/null || { echo "нет $TARGET-gcc — сначала ./build.sh" >&2; exit 1; }
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
mkdir -p "$WORK/src" "$WORK/kernel" "$OUT"

LINUX=$WORK/src/linux
[ -d "$LINUX" ] || git clone -q --depth 1 -b "$LINUX_BRANCH" https://github.com/frno7/linux "$LINUX"

# --- IOP-модули (firmware ps2/*.irx) ---
IOPMOD=$WORK/src/iopmod
if [ ! -f "$WORK/kernel/.iopmod" ]; then
	log "IOP-модули (iopmod)"
	[ -d "$IOPMOD" ] || git clone -q --depth 1 https://github.com/frno7/iopmod "$IOPMOD"
	# скрипт использует pipefail, а /bin/sh в Debian — dash
	sed -i '1s|^#!/bin/sh$|#!/bin/bash|' "$IOPMOD/script/iopmod-modc"
	make -C "$IOPMOD" -j"$JOBS" CROSS_COMPILE=$TARGET-
	touch "$WORK/kernel/.iopmod"
fi

# --- статический busybox (initramfs и rootfs используют один и тот же) ---
BB=$WORK/src/busybox
if [ ! -x "$WORK/kernel/busybox" ]; then
	log "busybox $BUSYBOX_REF (static)"
	[ -d "$BB" ] || git clone -q --depth 1 -b "$BUSYBOX_REF" https://github.com/mirror/busybox "$BB"
	make -C "$BB" -s distclean
	make -C "$BB" -s defconfig
	cfg() { sed -i "s/^\(# \)\?CONFIG_$1[ =].*/CONFIG_$1=$2/" "$BB/.config"; }
	cfg STATIC y
	sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "$BB/.config"          # не собирается с новыми заголовками
	sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' "$BB/.config"
	make -C "$BB" -s oldconfig </dev/null >/dev/null 2>&1 || true
	make -C "$BB" -j"$JOBS" CROSS_COMPILE=$TARGET- busybox
	$TARGET-strip -o "$WORK/kernel/busybox" "$BB/busybox"
fi

# --- статический e2fsck для проверки корня перед монтированием ---
E2=$WORK/src/e2fsprogs
if [ ! -x "$WORK/kernel/e2fsck" ]; then
	log "e2fsck (static)"
	[ -d "$E2" ] || git clone -q --depth 1 -b v1.47.4 https://github.com/tytso/e2fsprogs "$E2"
	rm -rf "$WORK/kernel/e2fs-build" && mkdir -p "$WORK/kernel/e2fs-build"
	(cd "$WORK/kernel/e2fs-build" &&
	 # musl ≥1.2.4: lseek64 — макрос при _LARGEFILE64_SOURCE, а не функция
	 "$E2/configure" --host=$TARGET --prefix=/usr --disable-nls --disable-fuse2fs \
		--disable-elf-shlibs --disable-uuidd --disable-defrag --disable-imager \
		--disable-resizer LDFLAGS=-static CFLAGS="-O2 -D_LARGEFILE64_SOURCE" \
		ac_cv_func_lseek64=yes >/dev/null &&
	 make -j"$JOBS" libs >/dev/null &&
	 make -j"$JOBS" -C e2fsck e2fsck >/dev/null)
	$TARGET-strip -o "$WORK/kernel/e2fsck" "$WORK/kernel/e2fs-build/e2fsck/e2fsck"
fi

# --- initramfs ---
IRFS=$WORK/kernel/initramfs
log "initramfs"
rm -rf "$IRFS"
mkdir -p "$IRFS"/{bin,sbin,usr/bin,usr/sbin,dev,proc,sys,tmp,newroot,lib/firmware/ps2}
cp "$WORK/kernel/busybox" "$IRFS/bin/busybox"
cp "$WORK/kernel/e2fsck" "$IRFS/sbin/e2fsck"
cp "$IOPMOD"/module/*.irx "$IRFS/lib/firmware/ps2/"
sed "s|@VIDEO@|$VIDEO|" "$TOP/files/initramfs-init" > "$IRFS/init"
chmod 755 "$IRFS/init"
# /dev/console нужен ядру до монтирования devtmpfs
cat > "$WORK/kernel/initramfs.list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
EOF

# --- ядро ---
cd "$LINUX"
if [ "$(cat "$WORK/kernel/.config-profile" 2>/dev/null)" != "$PROFILE" ]; then
	log "Конфигурация ядра: ps2_defconfig, профиль $PROFILE"
	make -s ps2_defconfig
	sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$IRFS $WORK/kernel/initramfs.list\"|" .config
	if [ "$PROFILE" = fast ]; then
		C=scripts/config
		# сжатый swap в RAM
		$C -m ZRAM -m ZSMALLOC -m CRYPTO_LZ4
		# отладка: память и лишняя работа без пользы для консоли
		$C -e EXPERT   # без него SLUB_DEBUG не выключается
		$C -d KALLSYMS_ALL -d SLUB_DEBUG -d PERF_EVENTS -d DEBUG_FS -d DEBUG_MEMORY_INIT \
		   -d DEBUG_INFO -d DEBUG_MISC
		# таймер и вытеснение — на пропускную способность
		$C -d HZ_250 -e HZ_100 --set-val HZ 100
		$C -d PREEMPT_VOLUNTARY -d PREEMPT -e PREEMPT_NONE
	fi
	make -s olddefconfig
	# убедиться, что зависимости Kconfig ничего не откатили
	if [ "$PROFILE" = fast ]; then
		for want in ZRAM=m CRYPTO_LZ4=m HZ=100 PREEMPT_NONE=y; do
			grep -qx "CONFIG_$want" .config || { echo "не применилось: CONFIG_$want" >&2; exit 1; }
		done
		for off in KALLSYMS_ALL SLUB_DEBUG PERF_EVENTS DEBUG_FS DEBUG_MEMORY_INIT DEBUG_INFO PREEMPT_VOLUNTARY; do
			grep -q "^CONFIG_$off=y" .config && { echo "не выключилось: CONFIG_$off" >&2; exit 1; }
		done
	fi
	echo "$PROFILE" > "$WORK/kernel/.config-profile"
fi
log "Ядро и модули"
make -j"$JOBS" vmlinux modules
rm -rf "$OUT/modules"
make -s modules_install INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1
KVER=$(make -s kernelrelease)
rm -f "$OUT/modules/lib/modules/$KVER"/{build,source}

# в initramfs — только модули из files/initramfs-modules и их зависимости
log "Модули initramfs"
MD=$OUT/modules/lib/modules/$KVER
declare -A need=()
add_mod() { # путь относительно $MD
	[ -n "${need[$1]:-}" ] && return
	need[$1]=1
	local d
	for d in $(sed -n "s|^$1: *||p" "$MD/modules.dep"); do add_mod "$d"; done
}
while read -r m; do
	case "$m" in ''|'#'*) continue;; esac
	p=$(grep -E "(^|/)(${m}|${m//-/_})\.ko:" "$MD/modules.dep" | head -1 | cut -d: -f1)
	[ -n "$p" ] || { echo "модуль $m не найден в modules.dep" >&2; exit 1; }
	add_mod "$p"
done < "$TOP/files/initramfs-modules"
for p in "${!need[@]}"; do install -Dm644 "$MD/$p" "$IRFS/lib/modules/$KVER/$p"; done
cp "$MD"/modules.{order,builtin,builtin.modinfo} "$IRFS/lib/modules/$KVER/" 2>/dev/null || true
depmod -b "$IRFS" "$KVER"
install -Dm644 "$TOP/files/initramfs-modules" "$IRFS/etc/initramfs-modules"
echo "в initramfs ${#need[@]} модулей, $(du -sh "$IRFS/lib/modules" | cut -f1)"
log "vmlinuz"
make -j"$JOBS" vmlinuz
cp vmlinuz "$OUT/VMLINUZ.ELF"
echo "$KVER" > "$OUT/kernel-release"
log "Готово: $OUT/VMLINUZ.ELF (ядро $KVER, видео по умолчанию $VIDEO)"
ls -lh "$OUT/VMLINUZ.ELF"
