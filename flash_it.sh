#!/bin/bash

CYAN='\033[36m'
NC='\033[0m'

# firmware is no longer separate
#echo -e "${CYAN}Flashing firmware from $(date -d "$(stat -c '%y' firmware/firmware.bin)" '+%B %d, %Y')${NC}"
#sudo openFPGALoader -b tangnano20k -f -o 0x500000 firmware/firmware.bin

echo -e "${CYAN}Flashing Bitstream from $(date -d "$(stat -c '%y' impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs)" '+%B %d, %Y - %T')${NC}"
sudo openFPGALoader -b tangnano20k -f impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs
