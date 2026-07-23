# Altirra 850 R: handler + relocator (third-party binaries — NOT committed)

The R:/modem feature serves the **Altirra 850 handler** (`850handler.bin`, 1281 B) and its
**relocator** (`850relocator.bin`, 341 B) to the Atari at coldstart, exactly as FujiNet does.
These two `.bin` files are Avery Lee's Altirra work, redistributed by the FujiNet project; they
are **intentionally git-ignored** here (see the repo `.gitignore` `*.bin` rule) so we don't
re-license or ship third-party binaries. Check their upstream license before ever bundling them
in a release image.

## How to obtain them
Download from the FujiNet firmware repo and drop them in this directory:

    fujinet-firmware/data/webui/device_specific/BUILD_ATARI/850handler.bin
    fujinet-firmware/data/webui/device_specific/BUILD_ATARI/850relocator.bin

Expected sizes: handler 1281 B, relocator 341 B.

## How they get onto the board
The firmware streams them from the SD card at `/PC/850HAND.BIN` and `/PC/850REL.BIN` during the
coldstart handler bootstrap (only when OSD Options → "Modem (R:)" is ON). Stage them with:

    python3 tools/atari.py send tools/fujinet_850/850handler.bin   PC/850HAND.BIN
    python3 tools/atari.py send tools/fujinet_850/850relocator.bin PC/850REL.BIN
