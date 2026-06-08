# 

.text
.global _start
.type _start, @function

# Firmware runs from a 32 KB BSRAM region [0x0000 .. 0x7FFF]. Stack grows DOWN
# from the top of that region. Must match baremetal.ld RAM LENGTH (32K) and the
# BSRAM depth (BRAM_DEPTH=8192 words). Keep text+rodata+data+bss below the stack.
.equ    STACK_TOP, 0x8000        # top of 32 KB BSRAM

_start:
    li  sp,STACK_TOP    # load stack pointer

# zero-init bss section
    la a0, _sbss
    la a1, _ebss
    bge a0, a1, end_init_bss
loop_init_bss:
    sw zero, 0(a0)
    addi a0, a0, 4
    blt a0, a1, loop_init_bss

end_init_bss:
    call main
    # tail exit
