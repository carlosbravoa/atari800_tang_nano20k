#ifndef FIRMWARE_H
#define FIRMWARE_H

#include <stdint.h>

// Load Atari OS and BASIC ROMs from SD card into SDRAM
int load_system_roms(void);

// Initialize SIO divisor
void sio_init(void);

// Poll SIO receiver and execute SIO commands
void sio_poll(void);

void message(char *msg, int center);
void status(char *msg);

#endif