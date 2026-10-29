// The game's own IOP module (the nameless 0x24700-byte IRX in PAC 098):
// the Yukes sound and streaming service, RPC ids 0x300 and 0x301. Layouts
// and names are from the DWARF its debug build left in IOP memory (source
// D:\ps2src\milmil\device\yiop_service\iop).
//
// The EE side queues jobs (0x276d60) that a worker thread (0x277000) sends
// with sifCallRpc. Every job receives into its own send buffer, and the
// completion callback (0x2776c0) reads nothing back for the calls the game
// makes before its frame loop, so returning the request unchanged is a
// complete reply for them.
package main

import "core:fmt"
import core "ps:core"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import kernel "ps:ps2/kernel"
import mem "ps:ps2/mem"

yukes_init :: proc() {
	iop.sif.servers[0x300] = yukes_300
	iop.sif.servers[0x301] = yukes_301
	core.snap_add(&yukes_report_addr)
	core.snap_add(&yukes_key)
}

// The CoreInfo report (spuCORE_ReportThread 0x1608): every vblank the
// module fills a tagspuCoreInfo with each voice's state (spuUpdateCore
// 0x1468) and DMAs its 0xe40 bytes to the ee_address 0x6a gave (0x394e00).
// It is 2 cores of 24 tagspuVoiceInfo, 0x4c bytes each (words): ENDX 0
// (this voice's bit, 0 or 1), PITCH 1, NAX 2, VOLXL 3, VOLXR 4, LSAX 5,
// ENVX 6, then from byte 0x1c the 48-byte key request that keyed the voice
// on, zeroed by key off (yukes_key). The EE reads only ENVX, as "still
// sounding", and the request's bank, pg_no and voice_id (0x29da80,
// 0x29db60, 0x29ddc0), so PITCH and the VOLX words are left 0.
@(private = "file")
YUKES_VOICE_INFO :: 0x4c
@(private = "file")
YUKES_CORE_INFO :: 24 * YUKES_VOICE_INFO

// The key request that keyed each voice on, by core and voice; zeroed by
// key off.
yukes_key: [2][24][48]u8

// The report's EE address, 0 until 0x6a.
@(private = "file")
yukes_report_addr: u32

@(private = "file")
yukes_host_vblank: proc()

// Report every vblank, after the host's own vblank work. Call after
// host.platform_init, which sets the hook.
yukes_hook :: proc() {
	yukes_host_vblank = kernel.vblank_hook
	kernel.vblank_hook = proc() {
		yukes_host_vblank()
		yukes_report()
	}
}

@(private = "file")
yukes_report :: proc() {
	if yukes_report_addr == 0 {return}
	out := mem.ram_slice(yukes_report_addr, 2 * YUKES_CORE_INFO)
	for c in 0 ..< 2 {
		for v in 0 ..< 24 {
			p := out[c * YUKES_CORE_INFO + v * YUKES_VOICE_INFO:][:YUKES_VOICE_INFO]
			s := iop.spu_voice_status(c, v)
			w := ([^]u32)(raw_data(p))
			w[0], w[1], w[2], w[3], w[4] = u32(s.endx), 0, s.nax, 0, 0
			w[5], w[6] = s.lsax, u32(s.envx)
			copy(p[0x1c:], yukes_key[c][v][:])
		}
	}
}

// fno 3: a command with no payload (0x277320).
@(private = "file")
yukes_300 :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool) {
	return fno == 3
}

// Every 0x301 command starts with a tagYIOPCmdID, eight words: client
// (0 EE), cmd_type (0 RPC, 1 RPC thread), rpc_stat, thread_stat, size,
// callbackfunc, callbackfunc_param and src_addr, the command's own EE
// address. The game sends its command blocks through their uncached
// mirror, so the real module DMAs status back into them, and the callback
// (0x277790) also copies the reply over the block for 0x68.
@(private = "file")
YIOP_RPC_STAT :: 2 // word; END when the call is done
@(private = "file")
YIOP_THREAD_STAT :: 3 // word; END_OK when the thread the call started is done
@(private = "file")
YIOP_RPC_END :: 2
@(private = "file")
YIOP_THREAD_END_OK :: 3

// The commands, each a header and then (byte offsets):
// 0x6a tagspuCoreInfoParam, 64 bytes at 0x395c40, sent once at init
//   (0x277390) after the EE clears 0xe40 bytes at 0x394e00: ee_address 0x20,
//   where the module's CoreInfo report goes (spuCORE_ReportInit, 0x1684).
// 0x6c tagspuEFFECT, 128 bytes at 0x395cc0 + 0x80*core (0x277390,
//   0x2775a0): MMIX 0x2c, then the effect {core, mode, depth_L (16-bit),
//   depth_R (16-bit), delay, feedback} at 0x30. Its callback ignores the reply.
// 0x6d typespuCoreVolumeParam, 64 bytes at 0x395dc0 + 0x40*core (0x277650):
//   core_no 0x20, MVOLL 0x24, MVOLR 0x26, VOLL 0x28, VOLR 0x2a (16-bit;
//   the game sets all four to one value).
// 0x67, 0x68 tagspuHDBDTrans: load and release sound bank n, 128 bytes at
//   0x395e40 + 0x80*n (0x2779b0, 0x277840): hd_ee 0x20, hd_iop 0x24,
//   hd_size 0x28, bd_ee 0x2c, bd_iop 0x30, bd_spu 0x34, bd_size 0x38,
//   trans_blocsize 0x3c, bank_index 0x40, bUsed 0x44, dma_ch 0x48. The bank
//   object (0x27a980) waits for thread_stat to read END_OK after a load and
//   for rpc_stat to read END after a release. With no audio, both are
//   reported done at once.
// 0x69 tagspuVoiceKeyTrans, 2368 bytes: nReq (0x920) key requests of 48
//   bytes from 0x20, each {core, bank, pg_no, note_no, pitch, velocity,
//   voll (16-bit, 0x18), volr (16-bit, 0x1a), pan 0x1c, command_target
//   (16-bit, 0x20), command_func (16-bit, 0x22), voice_id 0x24, user_id
//   0x28}. Its callback counts completions (0x398990).
@(private = "file")
yukes_301 :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool) {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x6a:
		yukes_report_addr = w[8]
		return true
	case 0x6c, 0x6d:
		return true
	case 0x67:
		if cpu.debug >= 1 {
			fmt.eprintfln("yukes: bank %d load hd %x+%x bd %x+%x to spu %x", w[0x10], w[8], w[10], w[11], w[14], w[13])
		}
		w[YIOP_THREAD_STAT] = YIOP_THREAD_END_OK
		return true
	case 0x68:
		w[YIOP_RPC_STAT] = YIOP_RPC_END
		return true
	case 0x69:
		if cpu.debug >= 1 {fmt.eprintfln("yukes: %d key requests", w[0x920 / 4])}
		return true
	}
	return false
}
