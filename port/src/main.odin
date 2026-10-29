// Berserk – Millennium Falcon (SLPM_656.88) on ps-recomp.
//
// Run from the repository root, or pass the disc directory as the first
// argument.
package main

import "core:fmt"
import "core:os"
import core "ps:core"
import "ps:ps2"
import host "ps:ps2/host"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

main :: proc() {
	disc := len(os.args) > 1 ? os.args[1] : "disc"
	iop.disc_dir = disc
	ps2.init()
	yukes_init()
	// Window, sound, pads, pacing and the per-vblank host work (SHOT, DUMP,
	// PRESS) all come from ps2/host.
	if !host.platform_init("Berserk - Millennium Falcon") {os.exit(1)}
	rec.register_all()
	// NATIVE_FILE: recomp's native_out blob replacing the Odin functions.
	if f := core.env("NATIVE_FILE"); f != "" {ps2.load_native(f)}
	data, err := os.read_entire_file(fmt.tprintf("%s/SLPM_656.88", disc), context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s/SLPM_656.88", disc)
		os.exit(1)
	}
	entry, loaded := mem.load_elf(data)
	if !loaded {
		fmt.eprintln("bad ELF")
		os.exit(1)
	}
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	ps2.run(entry)
}
