GOWIN_SH := $(HOME)/Documents/gowin/IDE/bin/gw_sh.sh

.PHONY: syn clean

# Stage 1: synthesis only — reports LUT/register count, no bitstream
syn:
	cd $(dir $(abspath $(lastword $(MAKEFILE_LIST)))) && $(GOWIN_SH) build.tcl

clean:
	rm -rf impl/
