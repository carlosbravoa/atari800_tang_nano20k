#!/bin/bash
# FatFs volume-safety regression suite for the firmware's disk layer.
# Property under test: NO sequence of firmware disk operations may damage the
# FAT volume. Every scenario runs on a fresh mkfs image and must leave it
# fsck-clean. Run from test/fatfs_host/. Exits nonzero on any failure.
set -u
cd "$(dirname "$0")"
MKFS=${MKFS:-/usr/sbin/mkfs.vfat}
FSCK=${FSCK:-/usr/sbin/fsck.fat}
PASS=0; FAIL=0

make -s fatfs_host || exit 1

mkatr() {  # $1=path  — 90K single-density ATR with a light pattern payload
python3 - "$1" << 'EOF'
import sys, struct
paras = 92160 // 16
hdr = struct.pack('<HHH', 0x0296, paras & 0xFFFF, 128) + bytes([paras >> 16]) + bytes(9)
body = bytearray(92160)
for s in range(720):
    body[s*128:(s+1)*128] = bytes((s + i) & 0xFF for i in range(128))
open(sys.argv[1], 'wb').write(hdr + bytearray(body))
EOF
}

mkatr_dd() {  # $1=path $2=layout (0=packed 384-B data origin, 1=768-B boot area)
              # 720x256 DD ATR; boot sectors 1-3 packed at 0/128/256 in BOTH
              # layouts (HW-proven MyDOS convention); every sector tagged
              # 'S' lo hi layout at its start.
python3 - "$1" "$2" << 'EOF'
import sys, struct
full = int(sys.argv[2])
n = 720
size = 16 + n*256 if full else 16 + 384 + (n-3)*256
paras = (size - 16) // 16
hdr = struct.pack('<HHH', 0x0296, paras & 0xFFFF, 256) + bytes([paras >> 16]) + bytes(9)
body = bytearray(size - 16)
for s in range(1, n + 1):
    if s <= 3:
        off = (s - 1) * 128
    else:
        off = (s - 1) * 256 if full else 384 + (s - 4) * 256
    body[off:off+4] = bytes([0x53, s & 0xFF, s >> 8, full])
open(sys.argv[1], 'wb').write(hdr + body)
EOF
}

fresh() {  # $1=image  $2=size-MB
    rm -f "$1"; truncate -s "${2}M" "$1"
    $MKFS "$1" > /dev/null || exit 1
}

check() {  # $1=name  $2=harness-exit  $3=image
    local fsck_out
    fsck_out=$($FSCK -n "$3" 2>&1); local fsck_rc=$?
    if [ "$2" -eq 0 ] && [ $fsck_rc -eq 0 ]; then
        echo "PASS  $1"; PASS=$((PASS+1))
    else
        echo "FAIL  $1  (harness=$2 fsck=$fsck_rc)"
        echo "$fsck_out" | sed 's/^/      /'
        FAIL=$((FAIL+1))
    fi
}

IMG=test.img
mkatr a.atr; mkatr b.atr

# 1. plain mount + SIO-pattern writes + readback
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_write /DISK1.ATR > /dev/null; check "s_write        " $? $IMG

# 2. duplicate mount guard (same ATR on D1+D2) — THE SD-killer scenario
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_dupguard /DISK1.ATR; check "s_dupguard     " $? $IMG

# 3. read-only attribute auto-heal (PC-copied R/O file)
fresh $IMG 64
./fatfs_host $IMG put a.atr /RODISK.ATR > /dev/null
./fatfs_host $IMG s_roattr /RODISK.ATR > /dev/null; check "s_roattr       " $? $IMG

# 4. New-blank-disk x6 (both slots) on a busy image
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG put b.atr /GAMES.ATR > /dev/null
./fatfs_host $IMG s_create 6 > /dev/null; check "s_create x6    " $? $IMG

# 5. SIO FORMAT (zero-fill) after dirtying
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_format /DISK1.ATR > /dev/null; check "s_format       " $? $IMG

# 6. stress: 500 interleaved 2-drive writes + dir listings + remounts
fresh $IMG 64
./fatfs_host $IMG put a.atr /D1.ATR > /dev/null
./fatfs_host $IMG put b.atr /D2.ATR > /dev/null
./fatfs_host $IMG s_stress /D1.ATR /D2.ATR 500 > /dev/null; check "s_stress 500   " $? $IMG

# 7. graceful behavior on a FULL filesystem (small FAT16 image)
fresh $IMG 4
./fatfs_host $IMG s_full; check "s_full         " $? $IMG

# 9. slot symmetry: same file both slots, sectors byte-identical (HW D2 mystery probe)
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_slotsym /DISK1.ATR > /dev/null; check "s_slotsym      " $? $IMG

# 10. out-of-range sector reads must fail AND not grow the image
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_eofread /DISK1.ATR; check "s_eofread      " $? $IMG

# 11. serial-bridge PUT: chunked create + overwrite + verify (firmware bridge_put_*)
fresh $IMG 64
./fatfs_host $IMG put a.atr /KEEP.ATR > /dev/null
./fatfs_host $IMG s_put /PC/DEEP/PUSHED.XEX > /dev/null; check "s_put          " $? $IMG

# 12. four drive slots: all mounted, all writable, dup-guard across all
fresh $IMG 64
for i in 1 2 3 4; do ./fatfs_host $IMG put a.atr /D$i.ATR > /dev/null; done
./fatfs_host $IMG s_fourslots > /dev/null; check "s_fourslots    " $? $IMG

# 13. H: device: create/write/read/append/dir/rename/delete/sanitize
fresh $IMG 64
./fatfs_host $IMG s_hdd > /dev/null; check "s_hdd          " $? $IMG

# 14. DD layouts: packed vs full-boot-sector images (the MyDOS-in-the-wild
#     flavor — sectors 4+ were served 384 bytes off before atr_dd_fullboot)
fresh $IMG 64
mkatr_dd dd_packed.atr 0; mkatr_dd dd_full.atr 1
./fatfs_host $IMG put dd_packed.atr /DDP.ATR > /dev/null
./fatfs_host $IMG put dd_full.atr /DDF.ATR > /dev/null
./fatfs_host $IMG s_ddlayout /DDP.ATR /DDF.ATR > /dev/null; check "s_ddlayout     " $? $IMG

# 8. INFORMATIONAL: the pre-guard bug — two raw write-FILs on one file.
#    Not a pass/fail gate; prints whether fsck sees damage (it demonstrates
#    what the dup-mount guard protects against).
fresh $IMG 64
./fatfs_host $IMG put a.atr /DISK1.ATR > /dev/null
./fatfs_host $IMG s_dupwrite_raw /DISK1.ATR > /dev/null
if $FSCK -n $IMG > /dev/null 2>&1; then
    echo "INFO  s_dupwrite_raw: volume survived this particular sequence"
else
    echo "INFO  s_dupwrite_raw: volume DAMAGED (as the FatFs docs warn) — guard justified"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
