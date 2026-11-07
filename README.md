# PS2 Linux для Debian/Ubuntu: тулчейн, ядро, система на флешке

Сборка `mipsr5900el-unknown-linux-musl` (binutils + GCC C/C++ + musl) для ядра
[frno7/linux](https://github.com/frno7/linux) без Gentoo. Это то же самое, что даёт
`crossdev -s4 -t mipsr5900el-unknown-linux-musl`, только обычными скриптами.
Поверх тулчейна — ядро и готовая система на USB-флешке (раздел 5).

Проверено на консоли? **Пока нет** — всё собрано и проверено в R5900-QEMU
(см. раздел 4); загрузку ядра, USB и видео на железе ещё предстоит проверить.
Целевая консоль — slim SCPH-7700x, вывод через компонентный кабель.

Порядок целиком:

```sh
./build.sh          # тулчейн (≈30–40 мин)
./build-kernel.sh   # ядро, IOP-прошивки, initramfs → out/VMLINUZ.ELF
./build-rootfs.sh   # система → out/rootfs
./make-image.sh     # образ флешки → out/ps2-usb.img
```

Структура репозитория:

| Путь | Что это |
|---|---|
| `build.sh` | кросс-тулчейн binutils + GCC + musl |
| `build-kernel.sh` | ядро frno7 (`PROFILE=fast`/`stock`), iopmod, initramfs |
| `build-rootfs.sh` | библиотеки и программы системы, сборка корня |
| `make-image.sh` | образ флешки FAT32 + ext4 без журнала (без root-прав) |
| `build-mc.sh` | отдельный статический mc (раздел 3) |
| `files/initramfs-init`, `files/initramfs-modules` | `/init` initramfs и список его модулей |
| `files/rootfs/etc/` | inittab, rcS, rc.conf, сеть, sshd, zram, mdev… |
| `patches/` | патч musl для R5900 (Fredrik Noring) |
| `tools/mkbkeymap.py` | раскладка us/ru в двоичном формате busybox `loadkmap` |
| `test/` | проверочные программы C и C++ |

Что делается:

- GCC и binutils собираются с триплетом `mipsr5900el-*`, поэтому по умолчанию
  `-march=r5900`, soft-float (у FPU R5900 нет double) и обход аппаратного бага
  R5900 «short loop» в ассемблере.
- musl патчится так же, как у frno7 (`patches/musl-r5900-ll-sc.patch`): инструкции
  LL/SC собираются через `.set mips2`, а ядро PS2 эмулирует их по trap.
- Заголовки ядра берутся из ветки `ps2-main` самого frno7/linux.

## 1. Тулчейн

```sh
sudo apt install build-essential bison flex texinfo gawk libgmp-dev libmpfr-dev \
     libmpc-dev libisl-dev rsync git wget xz-utils bc file
# необязательно — чтобы не качать binutils/GCC с gnu.org:
sudo apt install binutils-source gcc-12-source     # bookworm; на trixie gcc-14-source

./build.sh                    # → ~/x-tools/mipsr5900el
```

Переменные: `PREFIX=/opt/ps2`, `JOBS=8`, `SRC=git` (качать с GitHub-зеркал),
`GCC_VER=…`/`BINUTILS_VER=…` вместе с `GCC_FORCE=1`/`BINUTILS_FORCE=1`, чтобы
не брать версии из `/usr/src`. Скрипт перезапускаемый: готовые стадии помечаются
файлами `work/build/.*`.

## 2. Использование

```sh
export PATH=~/x-tools/mipsr5900el/bin:$PATH
mipsr5900el-unknown-linux-musl-gcc -static -O2 hello.c -o hello

# autotools
. ~/x-tools/mipsr5900el/bin/mipsr5900el-unknown-linux-musl-env
./configure --host=$PS2_HOST LDFLAGS=-static && make

# cmake
cmake -DCMAKE_TOOLCHAIN_FILE=~/x-tools/mipsr5900el/toolchain.cmake ..
```

Статическая линковка — самый простой вариант: на консоли не нужно ничего,
кроме бинарника. Динамическая тоже работает, но тогда на PS2 нужны
`/lib/ld-musl-mipsel-sf.so.1` и `libgcc_s`/`libstdc++` из sysroot.

## 3. Midnight Commander

```sh
sudo apt install meson ninja-build pkg-config autoconf automake libtool autopoint gettext libltdl-dev
./build-mc.sh                 # → out/ps2root и out/mc-ps2-4.8.32.tar.gz
```

Собирает статически zlib, libffi, pcre2, glib 2.74, ncursesw 6.4 и mc 4.8.32,
кладёт terminfo для `linux`, `xterm*`, `screen`, `tmux`, `vt100`.

Флешку лучше отформатировать в ext2/ext4: на FAT не сохранятся
симлинки и права, и mc потеряет `mc.keymap` (это симлинк). Распаковывать
архив на ПК:

```sh
sudo tar -C /media/usb -xzf out/mc-ps2-4.8.32.tar.gz    # → /media/usb/ps2root
```

На PS2:

```sh
mount /dev/sda1 /mnt
sh /mnt/ps2root/mc.sh
```

`mc.sh` ставит в корень (initramfs в RAM) симлинки `/etc/mc`, `/usr/share/mc`,
`/usr/libexec/mc` и `/usr/share/terminfo` на флешку и запускает mc. Ничего не
копируется, после перезагрузки следов не остаётся.

Чего нет: sftp-VFS (нужен libssh2), undelfs (e2fsprogs), локализации.
Добавляются по той же схеме, что и glib/ncurses в `build-mc.sh`.

## 4. Проверка без консоли

В QEMU из Debian/Ubuntu (8.x) модели R5900 для user-mode нет, а `-cpu 24Kf`
не поймает инструкции, которых нет у R5900. Нужен форк автора:

```sh
sudo apt install libglib2.0-dev zlib1g-dev
git clone --depth 1 https://github.com/frno7/qemu && cd qemu && mkdir build && cd build
../configure --target-list=mipsel-linux-user --static --disable-werror \
    --disable-docs --disable-tools --disable-system --disable-capstone --disable-git-update
sed -i 's/^GIT_SUBMODULES=.*/GIT_SUBMODULES=/' config-host.mak   # сабмодули для linux-user не нужны
make -j$(nproc)
```

После этого:

```sh
mipsr5900el-unknown-linux-musl-gcc -static -O2 test/hello.c -o hello
./qemu/build/mipsel-linux-user/qemu-mipsel -cpu R5900 ./hello
```

`test/hello.c` и `test/hello.cpp` проверяют printf, float/double, pthread,
атомики и исключения C++.

## 5. Своя система на флешке

### Что нужно на ПК

```sh
sudo apt install fdisk dosfstools mtools fakeroot kmod kbd console-setup python3 \
     meson ninja-build pkg-config autoconf automake libtool autopoint gettext libltdl-dev
```

Часть исходников (nano, bash, less, links2, socat, rsync, ncdu, frotz, gdb)
берётся через `apt-get source`. Для этого в источниках apt должен быть включён
`deb-src`: на Debian 12 добавь `deb-src` в `/etc/apt/sources.list`, на
Debian 13 и Ubuntu — `Types: deb deb-src` в `.sources`, затем `sudo apt update`.
Остальное скачивается с GitHub (git или архивы релизов).

### Ядро (`build-kernel.sh`)

- Ядро frno7 на `ps2_defconfig`, без новых драйверов. Два профиля:
  - `PROFILE=fast` (по умолчанию): плюс zram и LZ4 модулями; без отладочных
    опций (`KALLSYMS_ALL`, `SLUB_DEBUG`, `PERF_EVENTS`, `DEBUG_FS`,
    `DEBUG_MEMORY_INIT`, `DEBUG_INFO`); `HZ=100` и `PREEMPT_NONE`.
    После `olddefconfig` скрипт проверяет, что каждая опция применилась.
  - `PROFILE=stock`: `ps2_defconfig` как есть.
- IOP-модули ([frno7/iopmod](https://github.com/frno7/iopmod)) собираются тем же тулчейном.
- Свой initramfs: статический busybox, `e2fsck` и только модули из
  `files/initramfs-modules` (IOP, USB, хранилище, `ps2fb`) с зависимостями. Он поднимает IOP и USB, ждёт
  флешку, проверяет и монтирует ext4-раздел с меткой `ps2root` и делает `switch_root`.
  Если что-то пошло не так, открывается аварийная оболочка на экране.
- Видеорежим читается из `VIDEO.TXT` на FAT-разделе, его можно править на ПК.
  По умолчанию `1280x720p@60`: компонентный кабель, HD-режимы GS выводит в YPbPr.
  Другие варианты: `1280x720p@50`, `1920x1080i@60/50`, `720x480p@60`,
  `720x576p@50`; для композита или SCART — `640x448i@60` или `640x512i@50`.

### Система (`build-rootfs.sh`)

Всё собрано динамически с общими библиотеками (musl, ncursesw, glib, OpenSSL…),
кроме статического busybox:

| Группа | Программы |
|---|---|
| Основа | busybox (init, mdev, udhcpc, ntpd, vi, wget с HTTPS…), bash, e2fsprogs |
| Доступ | dropbear (SSH, scp), sftp-server из OpenSSH — работают WinSCP/FileZilla |
| Консоль | mc, nano, vim, less, htop, tmux, ncdu, tree, file, jq |
| Сеть | curl (OpenSSL, CA-сертификаты), links, irssi, rsync, socat, iperf3, tcpdump |
| Языки, отладка | lua 5.4, micropython, gdbserver |
| Игры | nethack, frotz, cmatrix |

OpenSSL взят вместо mbedTLS: links и irssi умеют TLS только через него.

Пересобрать один пакет: `REBUILD=1 ./build-rootfs.sh htop`. Добавить свой —
функция `b_имя` по образцу соседних и имя в списке `PROGS`.

### Флешка (`make-image.sh`)

- p1 — FAT32 64 МиБ (`VMLINUZ.ELF`, `VIDEO.TXT`, `README.TXT`);
- p2 — ext4 **без журнала**, `noatime`, только возможности, понятные ядру 5.4.

```sh
./make-image.sh                       # SIZE=4G ./make-image.sh — побольше
sudo dd if=out/ps2-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
sudo growpart /dev/sdX 2 && sudo resize2fs /dev/sdX2   # растянуть на всю флешку
```

### На консоли

1. Флешку в USB, клавиатуру во второй порт. В uLaunchELF запусти `mass:/VMLINUZ.ELF`.
2. Вход: `root`, без пароля. Сразу задай пароль: `passwd`, иначе SSH не пустит.
3. Настройки в `/etc/rc.conf`: сеть (`NET=dhcp|static|off`, `IFACE`), NTP,
   SSH, раскладка и шрифт, zram. Раскладка us/ru переключается Alt+Shift,
   шрифт консоли CyrSlav-Fixed16.
4. zram-swap включается при загрузке (`ZRAM=yes`, `ZRAM_SIZE=16M`,
   `ZRAM_ALGO=lz4`, `SWAPPINESS=100`). Посмотреть, сколько он сэкономил:
   `/etc/init.d/zram status`. Swap-файл на флешке, если задан `SWAPFILE`,
   идёт с меньшим приоритетом.
5. Сеть — USB-Ethernet на AX88179 (D-Link DUB-1312 и т. п.); драйвер в ядре
   frno7 уже есть. Модуль грузится сам при подключении (mdev).
6. С ПК: `ssh root@ps2`, `scp`, sftp; отладка: `gdbserver :1234 ./prog` на
   PS2 и `gdb-multiarch` на ПК.

Проверено в R5900-QEMU: все программы запускаются, все библиотеки на месте,
скрипты загрузки проходят проверку синтаксиса, e2fsck из initramfs понимает
раздел. **На консоли образ ещё не запускался**: загрузка ядра, USB и шрифт
`setfont` на `ps2fb` проверяются только на железе.

## Благодарности

- [Fredrik Noring (frno7)](https://github.com/frno7) — ядро
  [frno7/linux](https://github.com/frno7/linux), IOP-модули
  [iopmod](https://github.com/frno7/iopmod), поддержка R5900 в GCC/binutils,
  патч musl и [gentoo-mipsr5900el](https://github.com/frno7/gentoo-mipsr5900el),
  на который опирается этот проект.
- [meta-playstation2](https://github.com/andreacampanella/meta-playstation2) —
  идеи по графике, звуку и FPU для следующих шагов.

Скрипты скачивают исходники сторонних проектов при сборке; у каждого своя
лицензия.
