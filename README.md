# PS2 Linux on Debian/Ubuntu: toolchain, kernel, USB system

**English** | [Русский](README.ru.md)

Build scripts for running modern Linux on the PlayStation 2 with the
[frno7/linux](https://github.com/frno7/linux) kernel — no Gentoo required.

- A `mipsr5900el-unknown-linux-musl` cross toolchain (binutils + GCC C/C++ + musl),
  equivalent to `crossdev -s4 -t mipsr5900el-unknown-linux-musl`, built with plain scripts.
- The kernel with IOP firmware and an initramfs that boots from a USB stick.
- A small console system (busybox, SSH, mc, vim, curl, tmux, games…) and a
  ready-to-flash USB image.

**Tested on real hardware?** Partly: on a slim SCPH-7700x over SCART RGB the
kernel boots from USB, zram swap starts and the login prompt appears.
Networking, SSH and most programs are so far only checked in an R5900 QEMU
(see section 4). Target console: slim SCPH-7700x.
Hardware reports are very welcome — please open an issue.

Full sequence:

```sh
./build.sh          # toolchain (≈30–40 min)
./build-kernel.sh   # kernel, IOP firmware, initramfs → out/VMLINUZ.ELF
./build-rootfs.sh   # system → out/rootfs
./make-image.sh     # USB image → out/ps2-usb.img
```

Repository layout:

| Path | What it is |
|---|---|
| `build.sh` | cross toolchain: binutils + GCC + musl |
| `build-kernel.sh` | frno7 kernel (`PROFILE=fast`/`stock`), iopmod, initramfs |
| `build-rootfs.sh` | system libraries and programs, root filesystem assembly |
| `make-image.sh` | USB image: FAT32 + journal-less ext4 (no root needed) |
| `build-mc.sh` | standalone static Midnight Commander (section 3) |
| `files/initramfs-init`, `files/initramfs-modules` | initramfs `/init` and its module list |
| `files/rootfs/etc/` | inittab, rcS, rc.conf, network, sshd, zram, mdev… |
| `patches/` | musl patch for the R5900 (by Fredrik Noring) |
| `test/` | C and C++ test programs |

How the toolchain differs from a generic MIPS one:

- GCC and binutils are built for the `mipsr5900el-*` triplet, so they default to
  `-march=r5900`, soft-float (the R5900 FPU has no double precision) and the
  assembler workaround for the R5900 "short loop" hardware bug.
- musl gets the same patch frno7 uses (`patches/musl-r5900-ll-sc.patch`): LL/SC
  instructions are assembled with `.set mips2`, and the PS2 kernel emulates them
  on trap.
- Kernel headers come from the `ps2-main` branch of frno7/linux itself.

## 1. Toolchain

```sh
sudo apt install build-essential bison flex texinfo gawk libgmp-dev libmpfr-dev \
     libmpc-dev libisl-dev rsync git wget xz-utils bc file
# optional — avoids downloading binutils/GCC from gnu.org:
sudo apt install binutils-source gcc-12-source     # bookworm; gcc-14-source on trixie

./build.sh                    # → ~/x-tools/mipsr5900el
```

Variables: `PREFIX=/opt/ps2`, `JOBS=8`, `SRC=git` (fetch from GitHub mirrors),
`GCC_VER=…`/`BINUTILS_VER=…` together with `GCC_FORCE=1`/`BINUTILS_FORCE=1` to
ignore the versions in `/usr/src`. The script can be re-run: finished stages
are marked with `work/build/.*` stamp files.

## 2. Usage

```sh
export PATH=~/x-tools/mipsr5900el/bin:$PATH
mipsr5900el-unknown-linux-musl-gcc -static -O2 hello.c -o hello

# autotools
. ~/x-tools/mipsr5900el/bin/mipsr5900el-unknown-linux-musl-env
./configure --host=$PS2_HOST LDFLAGS=-static && make

# cmake
cmake -DCMAKE_TOOLCHAIN_FILE=~/x-tools/mipsr5900el/toolchain.cmake ..
```

Static linking is the simplest option: the console needs nothing but the
binary. Dynamic linking works too, but then the PS2 needs
`/lib/ld-musl-mipsel-sf.so.1` and `libgcc_s`/`libstdc++` from the sysroot.

## 3. Midnight Commander

```sh
sudo apt install meson ninja-build pkg-config autoconf automake libtool autopoint gettext libltdl-dev
./build-mc.sh                 # → out/ps2root and out/mc-ps2-4.8.32.tar.gz
```

Statically builds zlib, libffi, pcre2, glib 2.74, ncursesw 6.4 and mc 4.8.32,
and adds terminfo for `linux`, `xterm*`, `screen`, `tmux`, `vt100`.

Use an ext2/ext4 USB stick: FAT loses symlinks and permissions, and mc would
lose `mc.keymap` (a symlink). Unpack the archive on the PC:

```sh
sudo tar -C /media/usb -xzf out/mc-ps2-4.8.32.tar.gz    # → /media/usb/ps2root
```

On the PS2:

```sh
mount /dev/sda1 /mnt
sh /mnt/ps2root/mc.sh
```

`mc.sh` creates symlinks `/etc/mc`, `/usr/share/mc`, `/usr/libexec/mc` and
`/usr/share/terminfo` in the RAM root (initramfs) pointing to the stick, then
starts mc. Nothing is copied; nothing remains after a reboot.

Not included: sftp VFS (needs libssh2), undelfs (e2fsprogs), translations.
They can be added the same way as glib/ncurses in `build-mc.sh`.

## 4. Testing without a console

QEMU from Debian/Ubuntu (8.x) has no R5900 model in user mode, and `-cpu 24Kf`
won't catch instructions the R5900 lacks. Use frno7's fork:

```sh
sudo apt install libglib2.0-dev zlib1g-dev
git clone --depth 1 https://github.com/frno7/qemu && cd qemu && mkdir build && cd build
../configure --target-list=mipsel-linux-user --static --disable-werror \
    --disable-docs --disable-tools --disable-system --disable-capstone --disable-git-update
sed -i 's/^GIT_SUBMODULES=.*/GIT_SUBMODULES=/' config-host.mak   # submodules aren't needed for linux-user
make -j$(nproc)
```

Then:

```sh
mipsr5900el-unknown-linux-musl-gcc -static -O2 test/hello.c -o hello
./qemu/build/mipsel-linux-user/qemu-mipsel -cpu R5900 ./hello
```

`test/hello.c` and `test/hello.cpp` exercise printf, float/double, pthreads,
atomics and C++ exceptions.

## 5. A complete system on a USB stick

### Host requirements

```sh
sudo apt install fdisk dosfstools mtools fakeroot kmod python3 \
     meson ninja-build pkg-config autoconf automake libtool autopoint gettext libltdl-dev \
     cmake dpkg-dev tcl
```

Many sources (nano, bash, less, frotz, gdb, screen, lynx, angband, bsdgames,
gnugo and others) are fetched with `apt-get source` (Debian patches applied), so `deb-src` must be enabled: on Debian 12 add a
`deb-src` line to `/etc/apt/sources.list`; on Debian 13 and Ubuntu set
`Types: deb deb-src` in the `.sources` file; then run `sudo apt update`.
Everything else is downloaded from GitHub (git or release tarballs).

### Kernel (`build-kernel.sh`)

- The frno7 kernel on `ps2_defconfig`, no extra drivers. Two profiles:
  - `PROFILE=fast` (default): adds zram and LZ4 as modules; disables debug
    options (`KALLSYMS_ALL`, `SLUB_DEBUG`, `PERF_EVENTS`, `DEBUG_FS`,
    `DEBUG_MEMORY_INIT`, `DEBUG_INFO`); `HZ=100` and `PREEMPT_NONE`.
    After `olddefconfig` the script verifies that every option took effect.
  - `PROFILE=stock`: `ps2_defconfig` as is.
- IOP modules ([frno7/iopmod](https://github.com/frno7/iopmod)) are built with the same toolchain.
- Custom initramfs: static busybox, `e2fsck` and only the modules listed in
  `files/initramfs-modules` (IOP, USB, storage, `ps2fb`) plus their
  dependencies. It brings up the IOP and USB, waits for the stick, checks and
  mounts the ext4 partition labelled `ps2root`, and runs `switch_root`.
  If anything fails, a rescue shell opens on screen with the reason.
- The video mode is read from `VIDEO.TXT` on the FAT partition, editable on a PC.
  The GS outputs **SD modes as RGB** and **HD modes as YPbPr**, so the mode
  must match the cable:

  | Cable | Modes |
  |---|---|
  | SCART RGB, composite, S-video | `640x512i@50` (default, PAL with borders), `720x576i@50`, `720x288p@50`, `640x448i@60`, `720x480i@60` |
  | Component (YPbPr) | `1280x720p@60`, `1280x720p@50`, `1920x1080i@60/50`, `720x480p@60`, `720x576p@50` |

  An HD mode on a SCART RGB input gives a green, doubled picture.

### System (`build-rootfs.sh`)

Everything is dynamically linked against shared libraries (musl, ncursesw,
glib, OpenSSL…), except the static busybox:

| Group | Programs |
|---|---|
| Base | busybox (init, mdev, udhcpc, ntpd, vi, wget with HTTPS…), bash, e2fsprogs |
| Access | dropbear (SSH, scp), OpenSSH sftp-server — WinSCP/FileZilla work |
| Console | mc, nano, vim, less, htop, tmux, screen, ncdu, tree, file, jq, dialog, figlet |
| Utilities | strace, lsof, sqlite3, zip, unzip |
| Organizer | calcurse (calendar, to-do), sc-im (spreadsheet) |
| Network | curl (OpenSSL, CA certificates), links, lynx, irssi, rsync, socat, iperf3, tcpdump, mtr, nload, iftop, tintin++ (MUD client) |
| Languages, debugging | lua 5.4, micropython, gdbserver |
| Roguelikes | nethack, angband, brogue (`brogue`), umoria (`moria`) |
| Arcade, puzzles | vitetris, ninvaders, moon-buggy, nsnake, 2048, nudoku, freesweep, ttysolitaire, cmatrix |
| Strategy, board | gnugo, gnuchess, curseofwar, Text Elite (`txtelite`) |
| Text adventures | frotz, Zork I–III (`zork1`, `zork2`, `zork3`), adventure |
| bsdgames | atc, backgammon, battlestar, canfield, cribbage, gomoku, hangman, mille, monop, robots, sail, snake, trek, worm, wump, banner, pom… |

Games live in `/usr/games` (already in `PATH`). Zork saves go to the current directory.
The `evbug` debug module is removed from the image: it logged every key press
to `/var/log/messages`.

OpenSSL is used instead of mbedTLS because links and irssi only support TLS
through OpenSSL.

Rebuild a single package: `REBUILD=1 ./build-rootfs.sh htop`. To add your own,
write a `b_name` function modelled on its neighbours and add the name to `PROGS`.

### USB image (`make-image.sh`)

- p1 — FAT32, 64 MiB (`VMLINUZ.ELF`, `VIDEO.TXT`, `README.TXT`);
- p2 — ext4 **without a journal**, `noatime`, only features the 5.4 kernel understands.

```sh
./make-image.sh                       # SIZE=4G ./make-image.sh for a bigger one
sudo dd if=out/ps2-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
sudo growpart /dev/sdX 2 && sudo resize2fs /dev/sdX2   # grow to the whole stick
```

Why ext4 without a journal: USB 1.1 (~1 MB/s) is the bottleneck for any
filesystem, and a journal doubles writes. The initramfs runs `e2fsck -p`
before mounting, so an unclean shutdown is repaired automatically.

### On the console

1. USB stick in port 1, keyboard in port 2. FreeMcBoot → wLaunchELF →
   `mass:/VMLINUZ.ELF`. The screen stays black for a few seconds while the
   initramfs brings up the IOP and USB; the picture appears once `ps2fb` loads.
2. Log in as `root` with no password. Set one right away with `passwd`,
   otherwise SSH won't let you in.
3. Settings live in `/etc/rc.conf`: network (`NET=dhcp|static|off`, `IFACE`),
   NTP, SSH, zram, and an optional console keymap/font (`KEYMAP`, `FONT`;
   empty by default = US keyboard and the kernel's built-in font).
4. zram swap is enabled at boot (`ZRAM=yes`, `ZRAM_SIZE=16M`, `ZRAM_ALGO=lz4`,
   `SWAPPINESS=100`). See how much it saves with `/etc/init.d/zram status`.
   A swap file on the stick, if `SWAPFILE` is set, gets a lower priority.
5. Networking: a USB Ethernet adapter based on AX88179 (D-Link DUB-1312 and
   similar); the frno7 kernel already has the driver. The module loads
   automatically on hotplug (mdev).
6. From a PC: `ssh root@ps2`, `scp`, sftp. Debugging: `gdbserver :1234 ./prog`
   on the PS2 and `gdb-multiarch` on the PC.

No picture or a green, doubled one? The mode doesn't match the cable — see the
table in the kernel section and edit `VIDEO.TXT`. Add a one-button launch via FreeMcBoot
Configurator (an OSDSYS menu item or an E1 launch key pointing to
`mass:/VMLINUZ.ELF`).

Checked in the R5900 QEMU: all programs start, all libraries are present, boot
scripts pass a syntax check, and the initramfs `e2fsck` accepts the partition.
On hardware (SCPH-7700x, SCART RGB, `640x512i@50`) it boots to the login prompt.

## Credits

- [Fredrik Noring (frno7)](https://github.com/frno7) — the
  [frno7/linux](https://github.com/frno7/linux) kernel, IOP modules
  ([iopmod](https://github.com/frno7/iopmod)), R5900 support in GCC/binutils,
  the musl patch and [gentoo-mipsr5900el](https://github.com/frno7/gentoo-mipsr5900el),
  which this project builds upon.
- [meta-playstation2](https://github.com/andreacampanella/meta-playstation2) —
  ideas on graphics, sound and FPU for future work.
- Zork I–III — Infocom; released by Microsoft under the MIT licence
  ([historicalsource](https://github.com/historicalsource)).
- Text Elite — Ian Bell's `txtelite.c` 1.5 (published freely by the author, no formal
  licence), via [fragglet/txtelite](https://github.com/fragglet/txtelite).

The scripts download third-party sources at build time; each has its own licence.
