#!/usr/bin/env bash
# Статическая сборка Midnight Commander для PS2 Linux тулчейном из build.sh.
# Зависимости (zlib, libffi, pcre2, glib, ncurses) ставятся в sysroot тулчейна,
# сам mc — в out/ps2root (готово к копированию на флешку).
#
#   sudo apt install meson ninja-build pkg-config autoconf automake libtool \
#        autopoint gettext libltdl-dev
#   ./build-mc.sh
#
set -euo pipefail

TARGET=${TARGET:-mipsr5900el-unknown-linux-musl}
PREFIX=${PREFIX:-$HOME/x-tools/mipsr5900el}
SYSROOT=$PREFIX/$TARGET
TOP=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$TOP/work}/mc
OUT=${OUT:-$TOP/out/ps2root}
JOBS=${JOBS:-$(nproc)}

ZLIB_REF=v1.3.1
LIBFFI_REF=v3.4.6
PCRE2_REF=pcre2-10.42
GLIB_REF=2.74.7        # последняя ветка без gvdb-subproject и работает с meson из bookworm
NCURSES_REF=v6.4
MC_REF=4.8.32

export PATH=$PREFIX/bin:$PATH
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig
export PKG_CONFIG_PATH=
export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib STRIP=$TARGET-strip
export CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe"
command -v $CC >/dev/null || { echo "нет $CC — сначала ./build.sh" >&2; exit 1; }

mkdir -p "$WORK" "$OUT"
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
get() { # name github-repo ref
	[ -d "$WORK/$1" ] || { log "Загрузка $1 ($3)"; git clone -q --depth 1 -b "$3" "https://github.com/$2" "$WORK/$1"; }
	cd "$WORK/$1"
}
stamp() { [ -f "$WORK/.$1" ]; }
done_() { touch "$WORK/.$1"; }
HOSTCONF=(--host=$TARGET --prefix=/usr --disable-shared --enable-static)

if ! stamp zlib; then
	get zlib madler/zlib $ZLIB_REF
	log zlib
	CHOST=$TARGET ./configure --prefix=/usr --static
	make -j"$JOBS"
	make install DESTDIR="$SYSROOT"
	done_ zlib
fi

if ! stamp libffi; then
	get libffi libffi/libffi $LIBFFI_REF
	log libffi
	[ -x configure ] || ./autogen.sh
	./configure "${HOSTCONF[@]}" --disable-docs --disable-multi-os-directory
	make -j"$JOBS"
	make install DESTDIR="$SYSROOT"
	done_ libffi
fi

if ! stamp pcre2; then
	get pcre2 PCRE2Project/pcre2 $PCRE2_REF
	log pcre2
	[ -x configure ] || ./autogen.sh
	./configure "${HOSTCONF[@]}" --disable-jit --disable-pcre2grep-jit
	make -j"$JOBS"
	make install DESTDIR="$SYSROOT"
	done_ pcre2
fi

if ! stamp glib; then
	get glib GNOME/glib $GLIB_REF
	log glib
	# gvdb — git-сабмодуль с gitlab.gnome.org; если он недоступен, берём ту же
	# ревизию с GitHub-зеркала GNOME.
	if [ ! -f subprojects/gvdb/meson.build ]; then
		git submodule init subprojects/gvdb
		git submodule update subprojects/gvdb 2>/dev/null || {
			git config submodule.subprojects/gvdb.url https://github.com/GNOME/gvdb
			git submodule update subprojects/gvdb
		}
	fi
	cat > "$WORK/meson-cross.txt" <<EOF
[binaries]
c = '$TARGET-gcc'
cpp = '$TARGET-g++'
ar = '$TARGET-ar'
strip = '$TARGET-strip'
pkg-config = 'pkg-config'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$PKG_CONFIG_LIBDIR'

[host_machine]
system = 'linux'
cpu_family = 'mips'
cpu = 'r5900'
endian = 'little'
EOF
	rm -rf _build
	meson setup _build --cross-file "$WORK/meson-cross.txt" --prefix=/usr \
		--buildtype=release -Ddefault_library=static \
		-Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dlibelf=disabled \
		-Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dman=false \
		-Dgtk_doc=false -Ddtrace=false -Dsystemtap=false
	ninja -C _build -j"$JOBS"
	DESTDIR="$SYSROOT" ninja -C _build install
	done_ glib
fi

if ! stamp ncurses; then
	get ncurses mirror/ncurses $NCURSES_REF
	log ncurses
	./configure "${HOSTCONF[@]}" --without-shared --without-debug --without-ada \
		--without-cxx-binding --without-tests --without-progs --without-manpages \
		--enable-widec --enable-pc-files --disable-db-install --disable-stripping \
		--with-pkg-config-libdir=/usr/lib/pkgconfig \
		--with-default-terminfo-dir=/usr/share/terminfo \
		--with-terminfo-dirs=/usr/share/terminfo:/etc/terminfo:/lib/terminfo
	make -j"$JOBS"
	make install DESTDIR="$SYSROOT"
	done_ ncurses
fi

if ! stamp mc; then
	get mc MidnightCommander/mc $MC_REF
	log "mc $MC_REF"
	[ -x configure ] || ./autogen.sh
	# .la-файлы в sysroot сбивают libtool с путей — для статической сборки не нужны
	find "$SYSROOT/usr/lib" -name '*.la' -delete
	make distclean >/dev/null 2>&1 || true
	PKG_CONFIG="pkg-config --static" \
	./configure --host=$TARGET --prefix=/usr --sysconfdir=/etc \
		--with-screen=ncurses \
		--without-x --without-gpm-mouse --disable-nls --disable-vfs-sftp \
		--disable-aspell --disable-doxygen-doc --disable-tests
	# libtool выкидывает обычный -static; полностью статически — только -all-static
	make -j"$JOBS" LDFLAGS=-all-static
	rm -rf "$OUT" && make install DESTDIR="$OUT"
	$STRIP "$OUT/usr/bin/mc"
	file "$OUT/usr/bin/mc" | grep -q 'statically linked' || {
		echo "mc получился не статическим" >&2; exit 1; }
	done_ mc
fi

# terminfo: формат не зависит от архитектуры, берём скомпилированные записи хоста
log "terminfo"
for t in linux vt100 vt102 vt220 xterm xterm-256color xterm-color screen screen-256color tmux tmux-256color dumb ansi; do
	for d in /usr/share/terminfo /lib/terminfo /etc/terminfo; do
		f=$d/${t:0:1}/$t
		[ -f "$f" ] && { install -Dm644 "$f" "$OUT/usr/share/terminfo/${t:0:1}/$t"; break; }
	done
done

cat > "$OUT/mc.sh" <<'EOF'
#!/bin/sh
# Запуск mc прямо с флешки без chroot: sh /mnt/ps2root/mc.sh
# mc ищет данные по абсолютным путям (/etc/mc, /usr/share/mc, /usr/libexec/mc);
# корень PS2 Linux — initramfs в RAM, поэтому просто ставим туда симлинки.
R=$(cd "$(dirname "$0")" && pwd)
for p in etc/mc usr/share/mc usr/libexec/mc usr/share/terminfo; do
	[ -e "/$p" ] || { mkdir -p "/${p%/*}" && ln -s "$R/$p" "/$p"; }
done
export TERM=${TERM:-linux}
exec "$R/usr/bin/mc" "$@"
EOF
chmod +x "$OUT/mc.sh"

tar -C "$(dirname "$OUT")" -czf "$TOP/out/mc-ps2-$MC_REF.tar.gz" "$(basename "$OUT")"
log "Готово: $TOP/out/mc-ps2-$MC_REF.tar.gz"
file "$OUT/usr/bin/mc"
ls -lh "$OUT/usr/bin/mc"
