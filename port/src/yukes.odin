// The game's own IOP module (the nameless 0x24700-byte IRX in PAC 098):
// the Yukes sound and streaming service, RPC ids 0x300 and 0x301.
//
// The EE side queues jobs (0x276d60) that a worker thread (0x277000) sends
// with sifCallRpc. Every job receives into its own send buffer, and the
// completion callback (0x2776c0) reads nothing back for the calls the game
// makes before its frame loop, so returning the request unchanged is a
// complete reply for them.
package main

import "core:fmt"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"

yukes_init :: proc() {
	iop.sif.servers[0x300] = yukes_300
	iop.sif.servers[0x301] = yukes_301
}

// fno 3: a command with no payload (0x277320).
@(private = "file")
yukes_300 :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool) {
	return fno == 3
}

// fno 0x6a: 64-byte block at 0x395c40, sent once at init (0x277390).
// fno 0x6c: 128-byte voice/stream slot at 0x395cc0 + 0x80*n (0x277390,
// 0x2775a0); its callback ignores the reply.
// fno 0x6d: 64-byte block at 0x395dc0 + 0x40*n (0x277650).
// fno 0x67, 0x68: start and stop the stream in slot n, 128 bytes at
// 0x395e40 + 0x80*n (0x2779b0, 0x277840). The game sends the slot through
// its uncached mirror, and the slot holds its own address (word 7), so the
// real module DMAs status back into it; the callback (0x277790) also copies
// the reply over the slot. The stream object (0x27a980) waits for word 3 to
// read 3 after a start and for word 2 to read 2 after a stop. With no audio,
// both are reported done at once.
@(private = "file")
SLOT_STATE :: 2
@(private = "file")
SLOT_READY :: 3

@(private = "file")
yukes_301 :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool) {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x6a, 0x6c, 0x6d:
		return true
	case 0x67:
		if cpu.debug >= 1 {fmt.eprintfln("yukes: stream start %x", buf[:send_size])}
		w[SLOT_READY] = 3
		return true
	case 0x68:
		w[SLOT_STATE] = 2
		return true
	}
	return false
}
