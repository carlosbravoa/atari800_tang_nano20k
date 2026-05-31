#!/bin/bash

QT_QPA_PLATFORM=offscreen /home/carlos/Documents/gowin/IDE/bin/gw_sh.sh build.tcl
make -C firmware clean && make -C firmware
