# tools

`recomp.tsv` drives ps-recomp's `recomp` (r5900 backend). Paths are relative
to the repository root; `disc/` holds files extracted from the user's own
disc and is never committed.

## Code range

SLPM_656.88 (Metrowerks C 2.4.1.01) has no named sections: code and data
share one PROGBITS section at 0x100000-0x35cd00, so the options file gives
the range with `code_lo`/`code_hi`.

- 0x100000-0x2fe824: game and library code. The last function returns at
  0x2fe81c (delay slot 0x2fe820), followed by nop padding.
- 0x2fe880: a DMA tag (CNT, qwc 0xa9) and VIF MPG commands, a VU microcode
  packet. From here to 0x300c34 is data: libdma tables, VU packets and
  kernel patch code that runs at 0x8007xxxx, not on the EE. No `jal` in the
  code targets it.
- 0x357080-0x357410: five static initializers, run by the loop at 0x21c7d0
  through the table at 0x357410. Outside `code_hi`; a single range cannot
  include them without the data between.
