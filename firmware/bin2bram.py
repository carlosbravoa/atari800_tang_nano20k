#!/usr/bin/env python3
"""
bin2bram.py — convert firmware.bin into BSRAM init hex for the PicoRV32 boot RAM.

The PicoRV32 boot RAM is byte-laned: 4 independent byte-wide memories (one per
mem_wstrb bit) so per-byte writes (.data/.bss/stack) work natively and Gowin
infers clean BSRAM. This script emits one hex file per byte lane plus a combined
word-wide hex (handy for a single 32-bit-wide RAM variant / debugging).

Word i (little-endian) = bytes [4i, 4i+1, 4i+2, 4i+3]:
    lane0 = byte 4i+0  (mem_wstrb[0], mem_rdata[7:0])
    lane1 = byte 4i+1  (mem_wstrb[1], mem_rdata[15:8])
    lane2 = byte 4i+2  (mem_wstrb[2], mem_rdata[23:16])
    lane3 = byte 4i+3  (mem_wstrb[3], mem_rdata[31:24])

Usage:
    bin2bram.py firmware.bin out_dir DEPTH_WORDS
      out_dir/fw_lane0.hex .. fw_lane3.hex  (DEPTH_WORDS lines, 2 hex digits each)
      out_dir/fw_words.hex                  (DEPTH_WORDS lines, 8 hex digits each)
"""
import sys, os, struct

def main():
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} firmware.bin out_dir DEPTH_WORDS")
    bin_path, out_dir, depth = sys.argv[1], sys.argv[2], int(sys.argv[3])

    with open(bin_path, "rb") as f:
        data = f.read()
    # pad up to a word boundary
    while len(data) % 4:
        data += b"\x00"
    nwords = len(data) // 4
    if nwords > depth:
        sys.exit(f"ERROR: firmware is {nwords} words ({len(data)} bytes) > BSRAM depth "
                 f"{depth} words ({depth*4} bytes). Slim further or grow DEPTH_WORDS.")

    words = [struct.unpack_from("<I", data, 4*i)[0] for i in range(nwords)]
    words += [0] * (depth - nwords)          # zero-fill remainder (covers .bss/stack region)

    os.makedirs(out_dir, exist_ok=True)
    lanes = [open(os.path.join(out_dir, f"fw_lane{l}.hex"), "w") for l in range(4)]
    fw    = open(os.path.join(out_dir, "fw_words.hex"), "w")
    for w in words:
        fw.write(f"{w:08x}\n")
        for l in range(4):
            lanes[l].write(f"{(w >> (8*l)) & 0xFF:02x}\n")
    for fh in lanes:
        fh.close()
    fw.close()

    used = nwords * 4
    print(f"firmware: {used} bytes ({nwords} words) into {depth}-word "
          f"({depth*4}-byte) BSRAM — {100*used//(depth*4)}% full")
    print(f"  wrote {out_dir}/fw_lane0..3.hex and fw_words.hex ({depth} lines each)")

if __name__ == "__main__":
    main()
