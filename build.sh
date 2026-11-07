#!/usr/bin/env bash
# Кросс-тулчейн mipsr5900el-unknown-linux-musl для PlayStation 2 Linux (frno7/linux)
# Debian/Ubuntu, без Gentoo. binutils + GCC (C/C++) + musl + заголовки ядра PS2.
#
#   sudo apt install build-essential bison flex texinfo gawk libgmp-dev \
#        libmpfr-dev libmpc-dev libisl-dev rsync git wget xz-utils bc file
#   sudo apt install binutils-source gcc-12-source   # необязательно (bookworm; на trixie gcc-14-source)
#   ./build.sh                     # всё в ~/x-tools/mipsr5900el
#   PREFIX=/opt/ps2 ./build.sh     # свой путь
#   SRC=git ./build.sh             # брать исходники с GitHub-зеркал вместо gnu.org
#
# Если установлены пакеты *-source, исходники binutils/GCC берутся из /usr/src,
# без скачивания. Иначе — с ftp.gnu.org (или git при SRC=git).
#
set -euo pipefail

TARGET=${TARGET:-mipsr5900el-unknown-linux-musl}
PREFIX=${PREFIX:-$HOME/x-tools/mipsr5900el}
SYSROOT=$PREFIX/$TARGET
TOP=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$TOP/work}
JOBS=${JOBS:-$(nproc)}
SRC=${SRC:-tar}            # tar | git

BINUTILS_VER=${BINUTILS_VER:-2.42}
GCC_VER=${GCC_VER:-13.3.0}
MUSL_VER=${MUSL_VER:-1.2.5}
LINUX_BRANCH=${LINUX_BRANCH:-ps2-main}

export PATH=$PREFIX/bin:$PATH
mkdir -p "$WORK/src" "$WORK/build" "$PREFIX"
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

fetch() { # name ver tarball-url git-url git-ref [local-tarball]
	local name=$1 ver=$2 url=$3 giturl=$4 ref=$5 local=${6:-} dir=$WORK/src/$1-$2
	[ -d "$dir" ] && return
	if [ -n "$local" ] && [ -f "$local" ]; then
		log "Распаковка $name $ver из $local"
		tar -C "$WORK/src" -xf "$local"
	elif [ "$SRC" = git ]; then
		log "Загрузка $name $ver (git)"
		git clone -q --depth 1 -b "$ref" "$giturl" "$dir"
	else
		log "Загрузка $name $ver"
		wget -q -O "$WORK/src/${url##*/}" "$url"
		tar -C "$WORK/src" -xf "$WORK/src/${url##*/}"
	fi
}

# Debian/Ubuntu: исходники берутся из пакетов binutils-source и gcc-NN-source
# (/usr/src), если они установлены, — тогда версии подстраиваются под них.
DEB_BINUTILS=$(ls /usr/src/binutils/binutils-*.tar.* 2>/dev/null | head -1 || true)
DEB_GCC=$(ls /usr/src/gcc-*/gcc-*.tar.* 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$DEB_BINUTILS" ] && [ -z "${BINUTILS_FORCE:-}" ]; then
	BINUTILS_VER=$(basename "$DEB_BINUTILS" | sed -E 's/binutils-(.*)\.tar\..*/\1/')
fi
if [ -n "$DEB_GCC" ] && [ -z "${GCC_FORCE:-}" ]; then
	GCC_VER=$(basename "$DEB_GCC" | sed -E 's/gcc-(.*)\.tar\..*/\1/')
fi

fetch binutils "$BINUTILS_VER" \
	"https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz" \
	https://github.com/bminor/binutils-gdb "binutils-${BINUTILS_VER//./_}" "$DEB_BINUTILS"
fetch gcc "$GCC_VER" \
	"https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz" \
	https://github.com/gcc-mirror/gcc "releases/gcc-$GCC_VER" "$DEB_GCC"
fetch musl "$MUSL_VER" \
	"https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz" \
	https://github.com/kraj/musl "v$MUSL_VER"
if [ ! -d "$WORK/src/linux" ]; then
	log "Загрузка ядра frno7/linux ($LINUX_BRANCH) — только ради заголовков"
	git clone -q --depth 1 -b "$LINUX_BRANCH" https://github.com/frno7/linux "$WORK/src/linux"
fi

# --- патч musl: LL/SC через .set mips2 (ядро эмулирует их на R5900) ---
MUSL=$WORK/src/musl-$MUSL_VER
if ! grep -q _MIPS_ARCH_R5900 "$MUSL/arch/mips/atomic_arch.h"; then
	log "Патч musl для R5900 (LL/SC)"
	patch -d "$MUSL" -p1 < "$TOP/patches/musl-r5900-ll-sc.patch"
fi

stamp() { [ -f "$WORK/build/.$1" ]; }
done_() { touch "$WORK/build/.$1"; }

# --- 1. binutils ---
if ! stamp binutils; then
	log "binutils $BINUTILS_VER"
	rm -rf "$WORK/build/binutils" && mkdir -p "$WORK/build/binutils" && cd "$WORK/build/binutils"
	"$WORK/src/binutils-$BINUTILS_VER/configure" --target=$TARGET --prefix="$PREFIX" \
		--with-sysroot="$SYSROOT" --disable-nls --disable-werror --disable-multilib \
		--disable-gdb --disable-gdbserver --disable-sim --disable-gprofng
	make -j"$JOBS"
	make install
	done_ binutils
fi

# --- 2. заголовки ядра PS2 ---
if ! stamp headers; then
	log "Заголовки ядра (ARCH=mips)"
	make -C "$WORK/src/linux" ARCH=mips INSTALL_HDR_PATH="$SYSROOT/usr" headers_install >/dev/null
	done_ headers
fi

GCC_COMMON=(--target=$TARGET --prefix="$PREFIX" --with-sysroot="$SYSROOT"
	--disable-nls --disable-multilib --disable-werror --disable-libsanitizer
	--disable-libmudflap --disable-libssp --disable-libquadmath --disable-libgomp
	--disable-libitm --disable-libvtv --enable-tls --enable-deterministic-archives
	--with-build-sysroot="$SYSROOT")

# --- 3. GCC stage1 (только C, без libc) ---
if ! stamp gcc1; then
	log "GCC $GCC_VER stage 1"
	rm -rf "$WORK/build/gcc1" && mkdir -p "$WORK/build/gcc1" && cd "$WORK/build/gcc1"
	"$WORK/src/gcc-$GCC_VER/configure" "${GCC_COMMON[@]}" --enable-languages=c \
		--without-headers --with-newlib --disable-shared --disable-threads \
		--disable-libatomic --disable-libstdcxx
	make -j"$JOBS" all-gcc all-target-libgcc
	make install-gcc install-target-libgcc
	done_ gcc1
fi

# --- 4. musl ---
if ! stamp musl; then
	log "musl $MUSL_VER"
	rm -rf "$WORK/build/musl" && cp -a "$MUSL" "$WORK/build/musl" && cd "$WORK/build/musl"
	CC=$TARGET-gcc CROSS_COMPILE=$TARGET- ./configure --prefix=/usr --target=$TARGET \
		--syslibdir=/lib
	make -j"$JOBS"
	make DESTDIR="$SYSROOT" install
	done_ musl
fi

# --- 5. GCC final (C, C++) ---
if ! stamp gcc2; then
	log "GCC $GCC_VER final (C, C++)"
	rm -rf "$WORK/build/gcc2" && mkdir -p "$WORK/build/gcc2" && cd "$WORK/build/gcc2"
	"$WORK/src/gcc-$GCC_VER/configure" "${GCC_COMMON[@]}" --enable-languages=c,c++ \
		--enable-shared --enable-threads=posix --enable-libstdcxx-time \
		--disable-libstdcxx-pch
	make -j"$JOBS"
	make install
	done_ gcc2
fi

# --- 6. обёртки для ./configure и cmake ---
cat > "$PREFIX/bin/$TARGET-env" <<EOF
# source \$(which $TARGET-env)
export PATH="$PREFIX/bin:\$PATH"
export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib STRIP=$TARGET-strip
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PS2_SYSROOT="$SYSROOT" PS2_HOST=$TARGET
EOF
cat > "$PREFIX/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR mips)
set(CMAKE_C_COMPILER $PREFIX/bin/$TARGET-gcc)
set(CMAKE_CXX_COMPILER $PREFIX/bin/$TARGET-g++)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

log "Готово: $PREFIX/bin/$TARGET-gcc"
"$TARGET-gcc" -v 2>&1 | tail -1
