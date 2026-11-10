#!/usr/bin/env bash
# Образ флешки для PS2: MBR, p1 FAT32 (VMLINUZ.ELF, VIDEO.TXT), p2 ext4 без журнала.
# Права root не нужны (fakeroot).
#
#   ./make-image.sh                    # → out/ps2-usb.img (2 ГиБ)
#   SIZE=4G ./make-image.sh
#   sudo dd if=out/ps2-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
#
set -euo pipefail

TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$TOP/out}
IMG=${IMG:-$OUT/ps2-usb.img}
SIZE=${SIZE:-2G}
BOOT_MB=${BOOT_MB:-64}
VIDEO=${VIDEO:-640x512i@50}
ROOTFS=$OUT/rootfs

for t in sfdisk mkfs.vfat mcopy mke2fs fakeroot; do
	command -v $t >/dev/null || { echo "нет $t: sudo apt install fdisk dosfstools mtools e2fsprogs fakeroot" >&2; exit 1; }
done
[ -f "$OUT/VMLINUZ.ELF" ] || { echo "нет $OUT/VMLINUZ.ELF — ./build-kernel.sh" >&2; exit 1; }
[ -x "$ROOTFS/sbin/init" ] || [ -L "$ROOTFS/sbin/init" ] || { echo "нет rootfs — ./build-rootfs.sh" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
total=$(numfmt --from=iec "$SIZE")
mib=$((1024 * 1024))
p1_start=$mib                      # 1 МиБ — выравнивание
p1_size=$((BOOT_MB * mib))
p2_start=$((p1_start + p1_size))
p2_size=$((total - p2_start))

echo "==> FAT32 ($BOOT_MB МиБ)"
mkfs.vfat -F 32 -n PS2BOOT -C "$TMP/boot.img" $((p1_size / 1024)) >/dev/null
printf '%s\r\n' "$VIDEO" > "$TMP/VIDEO.TXT"
cat > "$TMP/README.TXT" <<EOF
PS2 Linux. Boot: FreeMcBoot -> wLaunchELF -> mass:/VMLINUZ.ELF
VIDEO.TXT - video mode (first line).
SCART RGB / composite / S-video (SD modes output RGB):
  640x512i@50 (PAL, default), 720x576i@50, 720x288p@50, 640x448i@60 (NTSC), 720x480i@60
Component cable (HD modes output YPbPr):
  1280x720p@60, 1280x720p@50, 1920x1080i@60, 1920x1080i@50, 720x480p@60, 720x576p@50
EOF
sed -i 's/$/\r/' "$TMP/README.TXT"
mcopy -i "$TMP/boot.img" "$OUT/VMLINUZ.ELF" "$TMP/VIDEO.TXT" "$TMP/README.TXT" ::/

# Явный набор возможностей ext4, которые понимает ядро 5.4. Новые mke2fs по
# умолчанию добавляют orphan_file и т. п. — такой раздел ядро 5.4 не смонтирует.
EXT4_FEATURES=ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,64bit,metadata_csum

echo "==> ext4 без журнала ($(numfmt --to=iec $p2_size))"
# fakeroot: в образе всё принадлежит root, даже если сборка шла от пользователя
fakeroot sh -c "
	chown -R 0:0 '$ROOTFS'
	chmod 600 '$ROOTFS/etc/shadow'
	mke2fs -q -t ext4 -O none,$EXT4_FEATURES -L ps2root -m 1 \
		-E root_owner=0:0 -d '$ROOTFS' '$TMP/root.img' $((p2_size / 1024))k
"

echo "==> Разметка"
rm -f "$IMG"
truncate -s "$total" "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
start=$((p1_start / 512)), size=$((p1_size / 512)), type=c, bootable
start=$((p2_start / 512)), size=$((p2_size / 512)), type=83
EOF
dd if="$TMP/boot.img" of="$IMG" bs=1M seek=$((p1_start / mib)) conv=notrunc,sparse status=none
dd if="$TMP/root.img" of="$IMG" bs=1M seek=$((p2_start / mib)) conv=notrunc,sparse status=none

echo "==> Готово: $IMG"
sfdisk -l "$IMG" | tail -3
echo "Записать: sudo dd if=$IMG of=/dev/sdX bs=4M conv=fsync status=progress"
echo "Растянуть ext4 на всю флешку (на ПК): sudo growpart /dev/sdX 2 && sudo resize2fs /dev/sdX2"
