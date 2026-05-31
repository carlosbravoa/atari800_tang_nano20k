#!/bin/bash

sudo openFPGALoader -b tangnano20k -f -o 0x500000 firmware/firmware.bin
sudo openFPGALoader -b tangnano20k -f impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs

