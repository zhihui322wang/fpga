ENTRY(reset_entry)

MEMORY
{
    ROM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
    . = ORIGIN(ROM);

    .text.bootloader : {
        KEEP(*(.text.bootloader))
        KEEP(*(.text.bootloader.*))
    } > ROM

    .text   : { *(.text*)   } > ROM
    .rodata : { *(.rodata*) } > ROM
    .data   : { *(.data*)   } > ROM

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > ROM

    . = ALIGN(4);
    _end = .;
    _stack_top = ORIGIN(ROM) + LENGTH(ROM);
}
