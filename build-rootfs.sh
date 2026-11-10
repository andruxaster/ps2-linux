#!/usr/bin/env bash
# rootfs для PS2 Linux: busybox + консольные программы, динамически с общим musl.
# Библиотеки ставятся в sysroot тулчейна, программы — в out/rootfs.
#
#   ./build-rootfs.sh                 # всё
#   ./build-rootfs.sh mc nano         # только эти пакеты (+ финальная сборка rootfs)
#   REBUILD=1 ./build-rootfs.sh htop  # пересобрать пакет
#
# Часть исходников берётся через `apt-get source` (nano, bash, less, links2,
# socat, rsync, ncdu, frotz, gdb) — нужен включённый deb-src.
set -euo pipefail

TARGET=${TARGET:-mipsr5900el-unknown-linux-musl}
PREFIX=${PREFIX:-$HOME/x-tools/mipsr5900el}
SYSROOT=$PREFIX/$TARGET
TOP=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$TOP/work}/rootfs
OUT=${OUT:-$TOP/out}
ROOTFS=$OUT/rootfs
JOBS=${JOBS:-$(nproc)}
SRC=$WORK/src
BLD=$WORK/build

export PATH=$PREFIX/bin:$PATH
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig
export PKG_CONFIG_PATH=
export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib
export STRIP=$TARGET-strip NM=$TARGET-nm LD=$TARGET-ld OBJDUMP=$TARGET-objdump
# -fcommon: старый код с глобальными переменными в заголовках (GCC 10+ иначе падает)
export CFLAGS="-O2 -pipe -fcommon" CXXFLAGS="-O2 -pipe" LDFLAGS=
# при кросс-сборке autoconf не может проверить malloc(0) и подставляет rpl_malloc
export ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
command -v $CC >/dev/null || { echo "нет $CC — сначала ./build.sh" >&2; exit 1; }
[ -x "$TOP/work/kernel/busybox" ] || { echo "нет busybox — сначала ./build-kernel.sh" >&2; exit 1; }

BUILD_TRIPLET=$(gcc -dumpmachine)
HOST=(--host=$TARGET --build=$BUILD_TRIPLET --prefix=/usr --sysconfdir=/etc
      --localstatedir=/var --disable-nls)
mkdir -p "$SRC" "$BLD" "$ROOTFS"
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ---------- исходники ----------
git_src() { # каталог репозиторий тег
	[ -d "$SRC/$1" ] || { log "git $2 $3"; git clone -q --depth 1 -b "$3" "https://github.com/$2" "$SRC/$1"; }
}
url_src() { # каталог url
	[ -d "$SRC/$1" ] && return
	log "Загрузка ${2##*/}"
	mkdir -p "$SRC/$1.tmp" && wget -q -O "$SRC/$1.tmp/a" "$2"
	mkdir -p "$SRC/$1" && tar -C "$SRC/$1" --strip-components=1 -xf "$SRC/$1.tmp/a"
	rm -rf "$SRC/$1.tmp"
}
deb_src() { # каталог пакет-источник
	[ -d "$SRC/$1" ] && return
	log "apt-get source $2"
	local d=$SRC/.deb-$2
	mkdir -p "$d" && (cd "$d" && apt-get source --download-only -qq "$2" >/dev/null 2>&1) || {
		echo "apt-get source $2 не сработал — включите deb-src в источниках apt" >&2; exit 1; }
	local t; t=$(ls "$d"/*.orig.tar.* | grep -v '\.asc$' | head -1)
	mkdir -p "$SRC/$1" && tar -C "$SRC/$1" --strip-components=1 -xf "$t"
}
fresh() { rm -rf "$BLD/$1"; mkdir -p "$BLD/$1"; cd "$BLD/$1"; }
insrc() { rm -rf "$BLD/$1"; cp -a "$SRC/$1" "$BLD/$1"; cd "$BLD/$1"; }
lib_install() { make install DESTDIR="$SYSROOT"; }
autoreconf_if() { [ -x configure ] || autoreconf -fi >/dev/null 2>&1 || autoreconf -fi; }
debx_src() { # пакет-источник: исходник Debian/Ubuntu вместе с патчами (dpkg-source -x)
	local d=$SRC/deb2-$1
	[ -d "$d" ] && return
	log "apt-get source $1 (с патчами)"
	mkdir -p "$SRC/.dl-$1" && (cd "$SRC/.dl-$1" && apt-get source --download-only -qq "$1" >/dev/null 2>&1) || {
		echo "apt-get source $1 не сработал — включите deb-src в источниках apt" >&2; exit 1; }
	dpkg-source -q -x "$(ls "$SRC/.dl-$1"/*.dsc | head -1)" "$d" >/dev/null
}
debx() { debx_src "$1"; insrc "deb2-$1"; }   # исходник с патчами → каталог сборки
# autotools-пакет: configure + make + install в rootfs
# старые config.sub/config.guess не знают ни хост, ни mipsr5900el — заменить свежими
fresh_config_sub() {
	local f n
	for n in config.sub config.guess; do
		f=$(ls /usr/share/misc/$n /usr/share/automake-*/$n 2>/dev/null | head -1)
		[ -n "$f" ] && find . -name $n -exec cp "$f" {} \;
	done
}
at_build() {
	autoreconf_if
	fresh_config_sub
	./configure "${HOST[@]}" "$@"
	make -j"$JOBS"
	make install DESTDIR="$ROOTFS"
}
GAMES=/usr/games

# ---------- библиотеки (в sysroot, shared + static) ----------
b_zlib() {
	git_src zlib madler/zlib v1.3.1; insrc zlib
	CHOST=$TARGET ./configure --prefix=/usr
	make -j"$JOBS"; lib_install
}
b_ncurses() {
	git_src ncurses mirror/ncurses v6.4; fresh ncurses
	"$SRC/ncurses/configure" "${HOST[@]}" --with-shared --with-normal --without-debug \
		--without-ada --without-cxx --without-cxx-binding --without-tests --without-progs \
		--without-manpages --enable-widec --enable-pc-files --disable-db-install \
		--disable-stripping --with-pkg-config-libdir=/usr/lib/pkgconfig \
		--with-default-terminfo-dir=/usr/share/terminfo \
		--with-terminfo-dirs=/etc/terminfo:/usr/share/terminfo
	make -j"$JOBS"; lib_install
	# программы, которые ищут -lncurses / <ncursesw/...>
	local L=$SYSROOT/usr/lib
	for l in ncurses form panel menu; do
		ln -sf lib${l}w.so "$L/lib$l.so"; ln -sf lib${l}w.a "$L/lib$l.a"
		ln -sf ${l}w.pc "$L/pkgconfig/$l.pc"
	done
	ln -sf libncursesw.so "$L/libcurses.so"; ln -sf libncursesw.so "$L/libtinfo.so"
	ln -sfn . "$SYSROOT/usr/include/ncursesw"
}
b_libffi() {
	url_src libffi https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
	fresh libffi
	"$SRC/libffi/configure" "${HOST[@]}" --disable-docs --disable-multi-os-directory
	make -j"$JOBS"; lib_install
}
b_pcre2() {
	url_src pcre2 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2
	fresh pcre2
	"$SRC/pcre2/configure" "${HOST[@]}" --disable-jit
	make -j"$JOBS"; lib_install
}
b_glib() {
	git_src glib GNOME/glib 2.74.7
	cd "$SRC/glib"
	if [ ! -f subprojects/gvdb/meson.build ]; then
		git submodule init subprojects/gvdb
		git submodule update subprojects/gvdb 2>/dev/null || {
			git config submodule.subprojects/gvdb.url https://github.com/GNOME/gvdb
			git submodule update subprojects/gvdb; }
	fi
	meson_cross > "$WORK/meson-cross.txt"
	rm -rf "$BLD/glib"
	meson setup "$BLD/glib" "$SRC/glib" --cross-file "$WORK/meson-cross.txt" --prefix=/usr \
		--buildtype=release -Ddefault_library=both -Dlibmount=disabled -Dselinux=disabled \
		-Dxattr=false -Dlibelf=disabled -Dtests=false -Dinstalled_tests=false -Dnls=disabled \
		-Dman=false -Dgtk_doc=false -Ddtrace=false -Dsystemtap=false
	ninja -C "$BLD/glib" -j"$JOBS"; DESTDIR="$SYSROOT" ninja -C "$BLD/glib" install
}
b_openssl() {
	url_src openssl https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz
	insrc openssl
	# no-asm: ассемблер OpenSSL для MIPS рассчитан на MIPS32; no-async: в musl нет *context()
	./Configure linux-generic32 no-asm no-async no-tests no-afalgeng shared \
		--prefix=/usr --openssldir=/etc/ssl --libdir=lib -O2 -latomic   # 64-битные атомики R5900 — через libatomic
	make -j"$JOBS"
	make install_sw DESTDIR="$SYSROOT"
	install -Dm755 apps/openssl "$ROOTFS/usr/bin/openssl"
}
b_libevent() {
	url_src libevent https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
	fresh libevent
	"$SRC/libevent/configure" "${HOST[@]}" --disable-openssl --disable-samples \
		--disable-libevent-regress --disable-debug-mode
	make -j"$JOBS"; lib_install
}
b_libpcap() {
	git_src libpcap the-tcpdump-group/libpcap libpcap-1.10.5; insrc libpcap
	autoreconf_if
	./configure "${HOST[@]}" --with-pcap=linux --disable-dbus --disable-rdma \
		--disable-bluetooth --without-libnl --disable-usb
	make -j"$JOBS"; lib_install
}

# ---------- программы (в rootfs) ----------
b_dropbear() {
	git_src dropbear mkj/dropbear DROPBEAR_2024.86; insrc dropbear
	autoreconf_if
	cat > localoptions.h <<'EOF'
#define SFTPSERVER_PATH "/usr/libexec/sftp-server"
#define DROPBEAR_PATH_SSH_PROGRAM "/usr/bin/dbclient"
#define DEFAULT_PATH "/usr/bin:/bin"
#define DEFAULT_ROOT_PATH "/usr/sbin:/usr/bin:/sbin:/bin"
EOF
	./configure "${HOST[@]}" --disable-pam --disable-lastlog --disable-utmp --disable-utmpx \
		--disable-wtmp --disable-wtmpx
	make -j"$JOBS" PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" MULTI=1 SCPPROGRESS=1
	install -Dm755 dropbearmulti "$ROOTFS/usr/sbin/dropbearmulti"
	ln -sf dropbearmulti "$ROOTFS/usr/sbin/dropbear"
	for p in dbclient dropbearkey dropbearconvert scp; do ln -sf ../sbin/dropbearmulti "$ROOTFS/usr/bin/$p"; done
	ln -sf dbclient "$ROOTFS/usr/bin/ssh"
}
b_sftpserver() {
	git_src openssh openssh/openssh-portable V_9_9_P1; insrc openssh
	autoreconf -fi   # в git configure старше m4 — configure сам требует autoreconf
	./configure "${HOST[@]}" --without-openssl --without-pam --disable-strip \
		--with-privsep-path=/var/empty
	make -j"$JOBS" sftp-server
	install -Dm755 sftp-server "$ROOTFS/usr/libexec/sftp-server"
}
b_e2fsprogs() {
	git_src e2fsprogs tytso/e2fsprogs v1.47.4; fresh e2fsprogs
	"$SRC/e2fsprogs/configure" "${HOST[@]}" --enable-elf-shlibs --disable-fuse2fs \
		--disable-uuidd --disable-imager \
		CFLAGS="$CFLAGS -D_LARGEFILE64_SOURCE" ac_cv_func_lseek64=yes
	make -j"$JOBS"
	make install DESTDIR="$ROOTFS"
}
b_mc() {
	git_src mc MidnightCommander/mc 4.8.32; insrc mc
	[ -x configure ] || ./autogen.sh
	./configure "${HOST[@]}" --with-screen=ncurses --without-x --without-gpm-mouse \
		--disable-vfs-sftp --disable-aspell --disable-doxygen-doc --disable-tests
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_nano() {
	deb_src nano nano; fresh nano
	"$SRC/nano/configure" "${HOST[@]}" --enable-utf8 --disable-libmagic
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_vim() {
	git_src vim vim/vim v9.1.0800; insrc vim
	vim_cv_toupper_broken=no vim_cv_terminfo=yes vim_cv_tgetent=zero \
	vim_cv_getcwd_broken=no vim_cv_stat_ignores_slash=no vim_cv_memmove_handles_overlap=yes \
	vim_cv_bcopy_handles_overlap=yes vim_cv_memcpy_handles_overlap=no \
	vim_cv_tty_group=world vim_cv_tty_mode=0620 \
	./configure "${HOST[@]}" --with-features=small --enable-multibyte --disable-gui \
		--without-x --disable-netbeans --disable-channel --disable-gpm --disable-sysmouse \
		--disable-selinux --disable-xsmp --disable-canberra --disable-libsodium \
		--with-tlib=ncursesw
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
	rm -rf "$ROOTFS"/usr/share/vim/vim*/{doc,tutor,spell,lang,print}
}
b_less() {
	deb_src less less; fresh less
	"$SRC/less/configure" "${HOST[@]}" --with-regex=posix
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_htop() {
	url_src htop https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz
	fresh htop
	ac_cv_file__proc_stat=yes ac_cv_file__proc_meminfo=yes \
	"$SRC/htop/configure" "${HOST[@]}" --enable-unicode
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_tmux() {
	url_src tmux https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz
	fresh tmux
	"$SRC/tmux/configure" "${HOST[@]}"
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_ncdu() {
	deb_src ncdu ncdu
	if ! grep -q 'AC_INIT(\[ncdu\], \[1\.' "$SRC/ncdu/configure.ac" 2>/dev/null && [ ! -f "$SRC/ncdu/configure" ]; then
		echo "ncdu: в этом дистрибутиве версия 2.x (на Zig) — пропускаю" >&2; return 0
	fi
	fresh ncdu
	"$SRC/ncdu/configure" "${HOST[@]}"
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_tree() {
	git_src tree Old-Man-Programmer/tree 2.1.3; insrc tree
	make CC="$CC" CFLAGS="$CFLAGS -DLINUX -D_FILE_OFFSET_BITS=64" LDFLAGS=
	install -Dm755 tree "$ROOTFS/usr/bin/tree"
}
b_file() {
	git_src file file/file FILE5_45
	cd "$SRC/file"; autoreconf_if
	# магическая база компилируется программой file той же версии на хосте
	rm -rf "$BLD/file-host"; mkdir -p "$BLD/file-host"; cd "$BLD/file-host"
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS \
		"$SRC/file/configure" --disable-shared --disable-libseccomp >/dev/null
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS make -j"$JOBS" >/dev/null
	fresh file
	"$SRC/file/configure" "${HOST[@]}" --disable-libseccomp --disable-bzlib \
		--disable-xzlib --disable-zstdlib --disable-lzlib
	make -j"$JOBS" FILE_COMPILE="$BLD/file-host/src/file"
	make install DESTDIR="$ROOTFS"
}
b_jq() {
	url_src jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz
	fresh jq
	"$SRC/jq/configure" "${HOST[@]}" --with-oniguruma=no --disable-docs \
		--disable-maintainer-mode --disable-valgrind
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_bash() {
	deb_src bash bash; fresh bash
	bash_cv_func_sigsetjmp=present bash_cv_job_control_missing=present \
	bash_cv_sys_named_pipes=present bash_cv_getcwd_malloc=yes \
	bash_cv_func_strcoll_broken=no bash_cv_unusable_rtsigs=no \
	"$SRC/bash/configure" "${HOST[@]}" --without-bash-malloc --enable-readline
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_rsync() {
	deb_src rsync rsync; fresh rsync
	"$SRC/rsync/configure" "${HOST[@]}" --disable-xxhash --disable-zstd --disable-lz4 \
		--disable-openssl --disable-md2man --disable-simd --disable-asm
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_socat() {
	deb_src socat socat; insrc socat   # socat не умеет собираться вне дерева
	# сдвиги полей termios для MIPS (при кросс-сборке configure их не вычисляет)
	sc_cv_sys_crdly_shift=9 sc_cv_sys_tabdly_shift=11 sc_cv_sys_csize_shift=4 \
	./configure "${HOST[@]}" --disable-readline --disable-libwrap
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_iperf3() {
	git_src iperf esnet/iperf 3.17.1; fresh iperf
	"$SRC/iperf/configure" "${HOST[@]}" --without-openssl --without-sctp --disable-static
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_tcpdump() {
	git_src tcpdump the-tcpdump-group/tcpdump tcpdump-4.99.5; insrc tcpdump
	autoreconf_if
	./configure "${HOST[@]}" --with-crypto=no --without-smi --without-cap-ng --disable-local-libpcap
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_links() {
	deb_src links2 links2; fresh links2
	"$SRC/links2/configure" "${HOST[@]}" --with-ssl --without-x --without-fb \
		--without-directfb --without-svgalib --without-libjpeg --without-libtiff \
		--without-librsvg --without-libwebp --without-libavif --without-zstd \
		--without-brotli --without-lzma --without-bzip2 --without-lzip --without-gpm \
		--disable-graphics
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_irssi() {
	url_src irssi https://github.com/irssi/irssi/releases/download/1.4.5/irssi-1.4.5.tar.xz
	meson_cross > "$WORK/meson-cross.txt"
	rm -rf "$BLD/irssi"
	meson setup "$BLD/irssi" "$SRC/irssi" --cross-file "$WORK/meson-cross.txt" --prefix=/usr \
		--buildtype=release -Dwith-perl=no -Dwith-otr=no -Dwith-proxy=no -Dwith-bot=no \
		-Dwith-fuzzer=no -Ddisable-utf8proc=yes -Denable-true-color=yes -Dinstall-glib=no
	ninja -C "$BLD/irssi" -j"$JOBS"; DESTDIR="$ROOTFS" ninja -C "$BLD/irssi" install
}
b_curl() {
	url_src curl https://github.com/curl/curl/releases/download/curl-8_10_1/curl-8.10.1.tar.xz
	fresh curl
	"$SRC/curl/configure" "${HOST[@]}" --with-openssl \
		--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --without-ca-path \
		--without-libpsl --disable-ldap --disable-ldaps --without-brotli --without-zstd \
		--without-nghttp2 --without-libidn2 --disable-docs --disable-manual --disable-static
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_lua() {
	git_src lua lua/lua v5.4.7; insrc lua
	$CC $CFLAGS -DLUA_USE_LINUX -DMAKE_LUA onelua.c -o lua -lm -ldl
	install -Dm755 lua "$ROOTFS/usr/bin/lua"   # luac.c есть только в релизных архивах lua.org
}
b_micropython() {
	url_src micropython https://github.com/micropython/micropython/releases/download/v1.24.0/micropython-1.24.0.tar.xz
	insrc micropython
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS -u LDFLAGS \
		make -C mpy-cross -j"$JOBS" >/dev/null
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS -u LDFLAGS \
		make -C ports/unix -j"$JOBS" CROSS_COMPILE=$TARGET- VARIANT=standard \
		MICROPY_PY_FFI=0 MICROPY_PY_SSL=0 MICROPY_PY_BTREE=0 MICROPY_STANDALONE=0 \
		PKG_CONFIG=pkg-config
	install -Dm755 ports/unix/build-standard/micropython "$ROOTFS/usr/bin/micropython"
}
b_gdbserver() {
	deb_src gdb gdb; fresh gdb
	"$SRC/gdb/configure" --host=$TARGET --build=$BUILD_TRIPLET --target=$TARGET --prefix=/usr \
		--disable-gdb --disable-sim --disable-binutils --disable-ld --disable-gas \
		--disable-gprof --disable-gprofng --disable-nls --disable-werror --without-python \
		--disable-libctf --enable-gdbserver --disable-gdbsupport-tests
	make -j"$JOBS" all-gdbserver LDFLAGS="-static-libstdc++ -static-libgcc"
	install -Dm755 gdbserver/gdbserver "$ROOTFS/usr/bin/gdbserver"
}
b_nethack() {
	git_src nethack NetHack/NetHack NetHack-3.6.7_Released; insrc nethack
	# утилиты (makedefs, lev_comp, …) работают на хосте, сама игра — на PS2
	sed -e 's|^#PREFIX=/usr$|PREFIX=/usr|' sys/unix/hints/linux > hints.ps2
	cat >> hints.ps2 <<EOF
HACKDIR=/usr/games/lib/nethackdir
SHELLDIR=/usr/games
VARDIR=/var/games/nethack
WINTTYLIB=-lncursesw
CHOWN=true
CHGRP=true
GAMEUID=root
GAMEGRP=root
EOF
	(cd sys/unix && sh setup.sh ../../hints.ps2) >/dev/null
	# сначала всё целиком хостовым компилятором: так появятся утилиты и данные
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS -u LDFLAGS \
		make -j1 all >/dev/null
	# затем игру — кросс-компилятором, не трогая готовые утилиты
	rm -f src/*.o src/nethack util/recover util/recover.o
	# -o: не пересоздавать хостовые утилиты и сгенерированные ими файлы
	local keep="" f
	for f in util/makedefs util/dgn_comp util/lev_comp util/dlb include/*.h src/*.c dat/*; do
		keep="$keep -o ../$f"
	done
	local cf; cf=$(sed -n 's/^CFLAGS+=//p' src/Makefile | tr '\n' ' ')
	make -C src -j"$JOBS" $keep CC="$CC" LINK="$CC" \
		CFLAGS="$CFLAGS -I../include -DNOTPARMDECL $cf" WINTTYLIB=-lncursesw nethack
	# recover — один файл; через util/Makefile он снова тянет пересборку makedefs
	local rcf=${cf//'$(HACKDIR)'//usr/games/lib/nethackdir}
	(cd util && eval "\$CC \$CFLAGS -I../include -DNOTPARMDECL $rcf -o recover recover.c")
	file src/nethack | grep -q MIPS
	local H=$ROOTFS/usr/games/lib/nethackdir
	install -Dm755 src/nethack "$H/nethack"
	install -Dm755 util/recover "$H/recover"
	install -m644 dat/nhdat dat/license dat/symbols "$H/" 2>/dev/null || install -m644 dat/nhdat dat/license "$H/"
	install -Dm644 sys/unix/sysconf "$H/sysconf"
	mkdir -p "$ROOTFS/var/games/nethack/save"
	touch "$ROOTFS"/var/games/nethack/{perm,record,logfile,xlogfile}
	install -Dm755 /dev/stdin "$ROOTFS/usr/games/nethack" <<'EOF'
#!/bin/sh
HACKDIR=/usr/games/lib/nethackdir NETHACKOPTIONS=${NETHACKOPTIONS:-} exec /usr/games/lib/nethackdir/nethack "$@"
EOF
}
b_frotz() {
	deb_src frotz frotz; insrc frotz
	# на PS2 все работают под root — убрать отказ «I won't run as root!»
	sed -i 's/if ((getuid() == 0) || (geteuid() == 0)) {/if (0) {/' src/curses/ux_init.c
	make -j"$JOBS" frotz CC="$CC" SOUND_TYPE=none CURSES=ncursesw PREFIX=/usr \
		CURSES_LDFLAGS="-lncursesw" SOUND=none
	install -Dm755 frotz "$ROOTFS/usr/games/frotz"
}
b_cmatrix() {
	git_src cmatrix abishekvashok/cmatrix v2.0; insrc cmatrix
	autoreconf_if
	# configure ищет каталоги шрифтов хоста; при кросс-сборке — ответить за него
	ac_cv_file__usr_lib_kbd_consolefonts=no ac_cv_file__usr_share_consolefonts=no \
	ac_cv_file__usr_lib_X11_fonts_misc=no ac_cv_file__usr_X11R6_lib_X11_fonts_misc=no \
	./configure "${HOST[@]}"
	make -j"$JOBS"
	install -Dm755 cmatrix "$ROOTFS/usr/bin/cmatrix"
}

# ---------- игры ----------
b_angband() {
	debx angband
	[ -x configure ] || ./autogen.sh >/dev/null
	./configure "${HOST[@]}" --bindir=$GAMES --enable-curses --disable-x11 --disable-sdl \
		--disable-sdl2 --with-private-dirs
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_brogue() {
	git_src brogue tmewett/BrogueCE v1.15.1; insrc brogue
	make -j"$JOBS" CC="$CC" TERMINAL=YES GRAPHICS=NO MAC_APP=NO RELEASE=YES \
		DATADIR=/usr/share/brogue bin/brogue
	install -Dm755 bin/brogue "$ROOTFS/usr/lib/brogue/brogue"
	cp -r bin/assets "$ROOTFS/usr/lib/brogue/" 2>/dev/null || true
	install -Dm755 /dev/stdin "$ROOTFS$GAMES/brogue" <<'EOF'
#!/bin/sh
# Brogue CE: terminal mode; saves and highscores go to ~/.brogue
mkdir -p "$HOME/.brogue" && cd "$HOME/.brogue" && exec /usr/lib/brogue/brogue --term "$@"
EOF
}
b_moria() {
	debx moria; mkdir -p _b; cd _b
	cmake .. -DCMAKE_TOOLCHAIN_FILE="$PREFIX/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_CXX_FLAGS="-O2 -DUMORIA_DATA_DIR=\\\"/usr/share/games/umoria\\\"" >/dev/null
	make -j"$JOBS"
	local o; o=$(find . -maxdepth 2 -type f -name umoria -perm -u+x | head -1)
	install -Dm755 "$o" "$ROOTFS/usr/lib/umoria/umoria"
	# таблица рекордов: umoria не создаёт её сама
	install -Dm666 /dev/null "$ROOTFS/var/games/moria/scores.dat"
	cp -r "$(dirname "$o")/data" "$ROOTFS/usr/lib/umoria/" 2>/dev/null || cp -r ../data "$ROOTFS/usr/lib/umoria/"
	install -Dm755 /dev/stdin "$ROOTFS$GAMES/moria" <<'EOF'
#!/bin/sh
# umoria looks for data/ next to the current directory; saves go to ~/.umoria
D=$HOME/.umoria; mkdir -p "$D"; cd "$D"
[ -e data ] || ln -s /usr/lib/umoria/data data
exec /usr/lib/umoria/umoria "$@"
EOF
}
b_vitetris() {
	debx vitetris
	./configure --prefix=/usr --bindir=$GAMES CC="$CC" --without-x --without-joystick \
		--without-network --enable-curses=no
	make -j"$JOBS" CC="$CC" LDFLAGS=
	install -Dm755 vitetris "$ROOTFS$GAMES/vitetris"
	ln -sf vitetris "$ROOTFS$GAMES/tetris"
}
b_ninvaders() {
	debx ninvaders
	make -j"$JOBS" CC="$CC" CFLAGS="$CFLAGS" LIBS=-lncursesw LDFLAGS=-lncursesw
	install -Dm755 nInvaders "$ROOTFS$GAMES/ninvaders"
}
b_moonbuggy() {
	debx moon-buggy
	autoreconf_if; fresh_config_sub
	./configure "${HOST[@]}" --bindir=$GAMES --localstatedir=/var/games
	make -j"$JOBS"
	# make install запускает сам moon-buggy (-c), чтобы создать таблицу рекордов,
	# — при кросс-сборке нельзя; без неё рекорды пишутся в ~/.mbscore
	install -Dm755 moon-buggy "$ROOTFS$GAMES/moon-buggy"
}
b_nsnake() {
	debx nsnake
	make -j"$JOBS" CXX="$CXX" CC="$CC" LDFLAGS="-lncursesw" CFLAGS_PLATFORM= \
		CXXFLAGS="$CXXFLAGS -Ideps"
	install -Dm755 bin/nsnake "$ROOTFS$GAMES/nsnake"
}
b_2048() {
	git_src 2048 mevdschee/2048.c main; insrc 2048
	$CC $CFLAGS -std=c99 2048.c -o 2048
	install -Dm755 2048 "$ROOTFS$GAMES/2048"
}
b_nudoku() {
	debx nudoku
	at_build --bindir=$GAMES --disable-cairo
}
b_freesweep() {
	debx freesweep
	at_build --bindir=$GAMES
}
b_ttysolitaire() {
	debx tty-solitaire
	make -j"$JOBS" CC="$CC" CFLAGS="$CFLAGS -std=c99 -fcommon -D_XOPEN_SOURCE_EXTENDED" LDFLAGS=-lncursesw
	install -Dm755 ttysolitaire "$ROOTFS$GAMES/ttysolitaire"
}
b_gnugo() {
	debx_src gnugo
	# patterns/ генерирует базы паттернов своими программами (mkpat, joseki…) —
	# их собираем и запускаем на хосте, а игру — кросс-компилятором
	rm -rf "$BLD/gnugo-host"; cp -a "$SRC/deb2-gnugo" "$BLD/gnugo-host"; cd "$BLD/gnugo-host"
	fresh_config_sub
	env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS -u CXXFLAGS -u LDFLAGS \
		sh -c './configure --without-readline >/dev/null && make -j'"$JOBS"' >/dev/null'
	insrc deb2-gnugo
	fresh_config_sub
	./configure "${HOST[@]}" --bindir=$GAMES --without-readline --disable-color
	# файлы, которые сгенерировали хостовые mkpat, joseki и др.
	cp "$BLD/gnugo-host"/patterns/*.{c,h,db} patterns/ 2>/dev/null || true
	sleep 1; touch patterns/*.db; sleep 1; touch patterns/*.c patterns/*.h
	# сгенерированные .c и .db больше не зависят от генераторов — make их не запускает
	sed -i -E '/^[^#[:space:]][^:=]*:/ s/ (mkpat|joseki|mkeyes|uncompress_fuseki|mkmcpat)\$\(EXEEXT\)//g' patterns/Makefile
	make -j"$JOBS"
	make install DESTDIR="$ROOTFS"
}
b_gnuchess() {
	debx gnuchess
	at_build --bindir=$GAMES --without-readline
}
b_curseofwar() {
	debx curseofwar
	make -j"$JOBS" CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="-lncursesw -lm" curseofwar
	install -Dm755 curseofwar "$ROOTFS$GAMES/curseofwar"
}
b_bsdgames() {
	debx bsdgames
	# configure спрашивает вопросы — ответы заранее в config.params
	cat > config.params <<EOF
bsd_games_cfg_non_interactive=y
bsd_games_cfg_install_prefix=$ROOTFS
bsd_games_cfg_gamesdir=$GAMES
bsd_games_cfg_sbindir=/usr/sbin
bsd_games_cfg_usrbindir=/usr/bin
bsd_games_cfg_libexecdir=/usr/lib/games
bsd_games_cfg_man6dir=/usr/share/man/man6
bsd_games_cfg_man8dir=/usr/share/man/man8
bsd_games_cfg_man5dir=/usr/share/man/man5
bsd_games_cfg_sharedir=/usr/share/games/bsdgames
bsd_games_cfg_varlibdir=/var/games/bsdgames
bsd_games_cfg_do_chown=n
bsd_games_cfg_use_dot_so=symlinks
bsd_games_cfg_gzip_manpages=n
bsd_games_cfg_cc=$CC
bsd_games_cfg_cxx=$CXX
bsd_games_cfg_optimize_flags="$CFLAGS"
bsd_games_cfg_other_cflags="-D_GNU_SOURCE -DBSD_GAMES_USE_TERMIOS -include sys/types.h -include fcntl.h"
bsd_games_cfg_ncurses_lib=-lncursesw
bsd_games_cfg_ncurses_includes=
bsd_games_cfg_openssl_lib=
bsd_games_cfg_openssl_includes=
bsd_games_cfg_no_build_dirs="boggle dm factor fortune hack hunt phantasia primes"
bsd_games_cfg_dictionary_src=/dev/null
bsd_games_cfg_pager=/usr/bin/less
bsd_games_cfg_use_libcrypto=n
EOF
	./configure >/dev/null
	# в musl нет <sys/cdefs.h> из glibc — заменить #include_next нужными макросами
	sed -i 's|^#include_next <sys/cdefs.h>|#ifdef __GLIBC__\n#include_next <sys/cdefs.h>\n#else\n#define __BEGIN_DECLS\n#define __END_DECLS\n#define __P(x) x\n#define __unused __attribute__((__unused__))\n#endif|' include/sys/cdefs.h
	# atc линкуется с -lfl ради одной функции yywrap
	if [ ! -f "$SYSROOT/usr/lib/libfl.a" ]; then
		echo 'int yywrap(void) { return 1; }' > "$BLD/yywrap.c"
		$CC $CFLAGS -c "$BLD/yywrap.c" -o "$BLD/yywrap.o"
		$AR rcs "$SYSROOT/usr/lib/libfl.a" "$BLD/yywrap.o"
	fi
	# adventure шифрует данные через random(); у glibc (хост) и musl (цель) разные
	# последовательности → свой одинаковый ГПСЧ в setup.c и io.c
	cat >> adventure/hdr.h <<'EOF'
static unsigned int adv_seed __attribute__((unused));
static void __attribute__((unused)) adv_srandom(unsigned int s) { adv_seed = s; }
static unsigned int __attribute__((unused)) adv_random(void)
{ adv_seed = adv_seed * 1103515245u + 12345u; return adv_seed >> 16; }
EOF
	sed -i 's/\bsrandom(SEED)/adv_srandom(SEED)/; s/\brandom()/adv_random()/g' adventure/setup.c adventure/io.c
	# adventure и monop генерируют данные своими программами — собрать их для хоста
	gcc -O2 -I. -Iinclude adventure/setup.c -o adventure/setup
	gcc -O2 -I. -Iinclude monop/initdeck.c -o monop/initdeck
	local o="-o adventure/setup -o monop/initdeck"
	make -j"$JOBS" $o
	make install INSTALL_PREFIX="$ROOTFS" $o
	ls "$ROOTFS$GAMES/robots" >/dev/null   # игры действительно установились
}
b_txtelite() {
	git_src txtelite fragglet/txtelite master; insrc txtelite
	$CC $CFLAGS txtelite.c -o txtelite -lm
	install -Dm755 txtelite "$ROOTFS$GAMES/txtelite"
	install -Dm644 docs/comments.txt "$ROOTFS/usr/share/doc/txtelite/comments.txt"
}
b_tintin() {
	debx tintin++; cd src
	ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
	./configure "${HOST[@]}" --bindir=/usr/bin
	make -j"$JOBS"
	install -Dm755 tt++ "$ROOTFS/usr/bin/tt++"
}
b_zork() {
	# Zork I–III: Microsoft выложила под MIT (2025), вместе с .z3 для Z-machine
	local z
	for z in zork1 zork2 zork3; do
		git_src "$z" "historicalsource/$z" master
		install -Dm644 "$SRC/$z/COMPILED/$z.z3" "$ROOTFS/usr/share/games/zork/$z.z3"
		install -Dm644 "$SRC/$z/LICENSE" "$ROOTFS/usr/share/doc/zork/LICENSE.$z"
		install -Dm755 /dev/stdin "$ROOTFS$GAMES/$z" <<EOF
#!/bin/sh
# Zork via frotz; saves go to the current directory
exec $GAMES/frotz "\$@" /usr/share/games/zork/$z.z3
EOF
	done
}

# ---------- утилиты, сеть, органайзер ----------
b_strace() {
	debx strace
	at_build --enable-mpers=no --disable-gcc-Werror --without-libdw --without-libunwind
}
b_lsof() {
	debx lsof
	LINUX_HASSELINUX=N LSOF_CC="$CC" LSOF_AR="$AR cr" LSOF_RANLIB="$RANLIB" LSOF_HOST=none \
	LSOF_VSTR=5.4 LSOF_MAKE=make ./Configure -n linux
	make -j"$JOBS" CC="$CC"
	install -Dm755 lsof "$ROOTFS/usr/bin/lsof"
}
b_screen() {
	debx screen
	[ -x configure ] || ./autogen.sh >/dev/null
	./configure "${HOST[@]}" --enable-colors256 --with-socket-dir=/run/screen \
		--with-pty-mode=0620 --with-pty-group=5 --disable-pam
	make -j"$JOBS"
	install -Dm755 screen "$ROOTFS/usr/bin/screen"
	install -Dm644 etc/etcscreenrc "$ROOTFS/etc/screenrc"
	mkdir -p "$ROOTFS/usr/share/screen"
}
b_dialog() {
	debx dialog
	at_build --with-ncursesw --disable-rpath-hack
}
b_sqlite() {
	debx sqlite3
	# lemon и mksourceid работают на хосте; патч Debian включает это через CROSS_BUILDING
	autoreconf_if; fresh_config_sub
	BUILD_CC=gcc BUILD_CFLAGS=-O2 ./configure "${HOST[@]}" --disable-tcl --disable-readline \
		--enable-editline=no --disable-static
	make -j"$JOBS" CROSS_BUILDING=yes
	make install DESTDIR="$ROOTFS" CROSS_BUILDING=yes
}
b_zip() {
	debx zip
	# configure zip не может проверить размеры типов при кросс-сборке — задать явно
	make -f unix/Makefile -j"$JOBS" generic CC="$CC" CPP="$CC -E" \
		LOCAL_ZIP="$CFLAGS -DLARGE_FILE_SUPPORT -DZIP64_SUPPORT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"
	install -Dm755 zip "$ROOTFS/usr/bin/zip"
}
b_unzip() {
	debx unzip
	make -f unix/Makefile -j"$JOBS" generic CC="$CC" CF="$CFLAGS -I. -DUNIX -DLARGE_FILE_SUPPORT -DUNICODE_SUPPORT -DUTF8_MAYBE_NATIVE -DNO_LCHMOD" LF2=
	install -Dm755 unzip "$ROOTFS/usr/bin/unzip"
}
b_lynx() {
	debx lynx
	at_build --with-ssl --with-screen=ncursesw --enable-default-colors --disable-nls \
		--with-zlib --without-bzlib --without-brotli --enable-ipv6
}
b_mtr() {
	debx mtr
	[ -x configure ] || ./bootstrap.sh >/dev/null 2>&1 || autoreconf -fi
	./configure "${HOST[@]}" --without-gtk --without-jansson --without-libcap
	make -j"$JOBS"; make install DESTDIR="$ROOTFS"
}
b_nload() {
	debx nload
	at_build
}
b_iftop() {
	debx iftop
	at_build --with-resolver=netdb
}
b_calcurse() {
	debx calcurse
	at_build --disable-docs --without-asciidoc
}
b_scim() {
	debx sc-im; cd src
	sed -i -e 's/^CFLAGS += -DXLSX$//' -e 's/^LDLIBS += -lxlsxwriter$//' Makefile
	make -j"$JOBS" CC="$CC" prefix=/usr NO_XLSX=1 NO_ODS=1 NO_LUA=1 \
		LDLIBS="-lncursesw -lm" CFLAGS_EXTRA= name=sc-im
	install -Dm755 sc-im "$ROOTFS/usr/bin/sc-im"
	install -Dm644 doc "$ROOTFS/usr/share/sc-im/sc-im_help" 2>/dev/null || true
}
b_figlet() {
	debx figlet
	# __BEGIN_DECLS/__END_DECLS есть только в glibc <sys/cdefs.h>
	make -j"$JOBS" CC="$CC" LD="$CC" CFLAGS="$CFLAGS -D__BEGIN_DECLS= -D__END_DECLS=" prefix=/usr \
		DEFAULTFONTDIR=/usr/share/figlet figlet chkfont figlist showfigfonts
	install -Dm755 figlet "$ROOTFS/usr/bin/figlet"
	mkdir -p "$ROOTFS/usr/share/figlet"; cp fonts/*.flf fonts/*.flc "$ROOTFS/usr/share/figlet/"
}

meson_cross() {
	cat <<EOF
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
}

LIBS="zlib ncurses libffi pcre2 glib openssl libevent libpcap"
PROGS="dropbear sftpserver e2fsprogs mc nano vim less htop tmux ncdu tree file jq bash
       rsync socat iperf3 tcpdump links irssi curl lua micropython gdbserver nethack
       frotz cmatrix
       strace lsof screen dialog sqlite zip unzip lynx mtr nload iftop calcurse scim figlet
       angband brogue moria vitetris ninvaders moonbuggy nsnake 2048 nudoku freesweep
       ttysolitaire gnugo gnuchess curseofwar bsdgames txtelite tintin zork"

run() {
	local p=$1
	if [ -f "$WORK/.done-$p" ] && [ -z "${REBUILD:-}" ]; then return; fi
	log "$p"
	# не «( … ) || …»: в таком контексте bash игнорирует set -e внутри функции
	local rc=0
	set +e; ( set -e; "b_$p" ); rc=$?; set -e
	[ $rc -eq 0 ] || { echo "!!! $p: ошибка сборки (лог выше)" >&2; return 1; }
	touch "$WORK/.done-$p"
}

if [ $# -gt 0 ]; then LIST="$*"; else LIST="$LIBS $PROGS"; fi
for p in $LIST; do run "$p"; done
[ -n "${SKIP_ROOT:-}" ] && exit 0   # только пакеты, без сборки корня

# ---------- сборка корня ----------
if [ ! -f "$OUT/kernel-release" ]; then
	echo "Пакеты собраны; корень соберётся после ./build-kernel.sh (нужны модули ядра)." >&2
	exit 0
fi
log "Корень: busybox, библиотеки, модули, настройки"
KVER=$(cat "$OUT/kernel-release")
cd "$ROOTFS"
mkdir -p bin sbin lib usr/bin usr/sbin usr/lib dev proc sys tmp run root var/log var/empty \
	etc/ssl/certs etc/dropbear mnt media/usb home
chmod 700 root; chmod 1777 tmp

install -m755 "$TOP/work/kernel/busybox" bin/busybox
[ -f "$TOP/work/src/busybox/busybox.links" ] ||
	make -C "$TOP/work/src/busybox" -s CROSS_COMPILE=$TARGET- busybox.links
# ссылки на апплеты — только если настоящей программы с таким именем нет ни в
# одном из bin/sbin (иначе, например, busybox mke2fs в /sbin заслонит e2fsprogs)
while read -r l; do
	n=${l##*/} real=
	for d in bin sbin usr/bin usr/sbin; do
		[ -e "$d/$n" ] && [ "$(readlink "$d/$n")" != /bin/busybox ] && real=1
	done
	[ -n "$real" ] && { [ "$(readlink ".$l")" = /bin/busybox ] && rm -f ".$l"; continue; }
	[ -e ".$l" ] || [ -L ".$l" ] || ln -s /bin/busybox ".$l"
done < "$TOP/work/src/busybox/busybox.links"

# общие библиотеки: musl, libgcc_s/libstdc++, то, что собрано в sysroot
cp -a "$SYSROOT"/lib/*.so* lib/ 2>/dev/null || true
for f in "$SYSROOT"/usr/lib/*.so*; do cp -a "$f" usr/lib/; done
ln -sf /usr/lib/libc.so lib/ld-musl-mipsel-sf.so.1

# модули ядра и индексы
rm -rf lib/modules && cp -a "$OUT/modules/lib/modules" lib/
# evbug — отладочный драйвер, пишет в лог каждое событие ввода и подходит к любой
# клавиатуре; modprobe из busybox не умеет чёрный список, поэтому модуль удаляется
find lib/modules -name evbug.ko -delete
depmod -b "$ROOTFS" "$KVER"

# настройки из files/rootfs
cp -a "$TOP/files/rootfs/." "$ROOTFS/"
chmod 755 etc/init.d/*
install -m755 "$TOP/work/src/busybox/examples/udhcp/simple.script" usr/share/udhcpc/default.script
cat > etc/passwd <<'EOF'
root:x:0:0:root:/root:/usr/bin/bash
daemon:x:1:1:daemon:/:/bin/false
nobody:x:65534:65534:nobody:/:/bin/false
EOF
cat > etc/shadow <<'EOF'
root::0:0:99999:7:::
daemon:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
EOF
chmod 600 etc/shadow
cat > etc/group <<'EOF'
root:x:0:
daemon:x:1:
tty:x:5:
disk:x:6:
video:x:44:
nogroup:x:65534:
EOF
printf '/bin/sh\n/bin/ash\n/usr/bin/bash\n' > etc/shells
printf '127.0.0.1\tlocalhost\n127.0.1.1\tps2\n' > etc/hosts
cat > etc/os-release <<'EOF'
NAME="PS2 Linux"
ID=ps2linux
PRETTY_NAME="PS2 Linux (frno7 kernel, musl, busybox)"
EOF
cat > etc/motd <<'EOF'

  PlayStation 2 Linux - mc, nano, vim, htop, tmux, links, irssi, curl, rsync...
  Settings: /etc/rc.conf. zram status: /etc/init.d/zram status.
  Games: nethack, frotz, cmatrix.

EOF
cp /etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ca-certificates.crt
ln -sf certs/ca-certificates.crt etc/ssl/cert.pem
touch etc/resolv.conf

# terminfo (формат не зависит от архитектуры) — скомпилированные записи хоста
for t in linux vt100 vt102 vt220 xterm xterm-256color xterm-color screen screen-256color \
	 tmux tmux-256color rxvt-unicode rxvt-unicode-256color dumb ansi putty putty-256color; do
	for d in /usr/share/terminfo /lib/terminfo /etc/terminfo; do
		f=$d/${t:0:1}/$t
		[ -f "$f" ] && { install -Dm644 "$f" "usr/share/terminfo/${t:0:1}/$t"; break; }
	done
done

# лишнее для консоли без компилятора
rm -rf usr/include usr/share/{man,info,doc,gtk-doc,aclocal,bash-completion} usr/lib/pkgconfig
find usr/lib lib -name '*.a' -delete -o -name '*.la' -delete
# strip всех ELF
find . -type f ! -path './lib/modules/*' -exec sh -c '
	for f; do case "$(head -c4 "$f" 2>/dev/null)" in "$(printf "\177ELF")") '"$STRIP"' --strip-unneeded "$f" 2>/dev/null;; esac; done' _ {} +

log "Готово: $ROOTFS ($(du -sh "$ROOTFS" | cut -f1))"
