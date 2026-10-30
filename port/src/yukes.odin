// The game's own IOP module (_IRX300.PAC entry 098): the Yukes sound and
// streaming service, RPC ids 0x300 and 0x301. Layouts and names are from the
// DWARF its debug build left in IOP memory (source
// D:\ps2src\milmil\device\yiop_service\iop). Sound effects are Sony HD/BD
// banks the module plays with sdhd.irx lookups and libsd voice registers;
// this file does the same against ps-recomp's SPU voices.
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

@(private = "file")
BANKS :: 32
// The EE's bank table holds an HD of at most this many bytes per slot.
@(private = "file")
HD_MAX :: 8192
@(private = "file")
CORES :: 2
@(private = "file")
VOICES :: 24
@(private = "file")
KEY_SIZE :: 48
// The module's master voice volume, per core, until 0x6d sets it.
@(private = "file")
VOL_FULL :: 0x3fff

@(private = "file")
Yukes_Bank :: struct {
	hd:     [HD_MAX]u8,
	bd_spu: u32, // where the bank's BD sits in sound RAM
}

// What the module keeps per voice besides the key: the PITCH, VOLL and VOLR
// it last wrote (ps-recomp's voice set takes all three at once) and the
// pitch a pause saved.
@(private = "file")
Yukes_Voice :: struct {
	pitch, voll, volr: u32,
	last_pitch:        u32,
	paused:            bool,
}

@(private = "file")
yukes: struct {
	bank:   [BANKS]Yukes_Bank,
	loaded: bit_set[0 ..< BANKS],
	master: [CORES]u32,
	voice:  [CORES][VOICES]Yukes_Voice,
	// Keyed on since the last mix. ps-recomp's key on starts the envelope
	// at 0 and only the mix raises it, where the module's key_on waits a
	// tick (Wait2TsThread) before the next scan; these count as sounding.
	fresh:  [CORES]bit_set[0 ..< VOICES],
}

// The tagspuVoiceKey each voice was keyed on with, zeroed by a key off: the
// module's s_spuCoreInfo voice entries from +0x1c.
yukes_key: [CORES][VOICES][KEY_SIZE]u8

yukes_init :: proc() {
	yukes.master = VOL_FULL
	core.snap_add(&yukes)
	core.snap_add(&yukes_key)
	core.snap_add(&yukes_report_addr)
	core.snap_add(&yukes_effect)
	iop.sif.servers[0x300] = yukes_300
	iop.sif.servers[0x301] = yukes_301
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
YUKES_CORE_INFO :: VOICES * YUKES_VOICE_INFO

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
		yukes.fresh = {}
		yukes_report()
		yukes_effect_tick()
	}
}

@(private = "file")
yukes_report :: proc() {
	if yukes_report_addr == 0 {return}
	out := mem.ram_slice(yukes_report_addr, CORES * YUKES_CORE_INFO)
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			p := out[c * YUKES_CORE_INFO + v * YUKES_VOICE_INFO:][:YUKES_VOICE_INFO]
			s := iop.spu_voice_status(c, v)
			w := ([^]u32)(raw_data(p))
			w[0], w[1], w[2], w[3], w[4] = u32(s.endx), 0, s.nax, 0, 0
			w[5], w[6] = s.lsax, u32(s.envx)
			copy(p[0x1c:], yukes_key[c][v][:])
		}
	}
}

// An effect change (spu_CoreEffectThread 0x2a60): the return volume
// ramps from where it is to 0 in 25 steps 16 ms apart, the effect goes off,
// the new mode is set with depth 0 and the work area cleared, the effect
// goes on, and the depth ramps up to the new one in 25 steps. A semaphore
// runs the module's changes one at a time; here one step is one vblank.
// MMIX, delay and feedback are not applied (ps-recomp's reverb takes none).
@(private = "file")
EFFECT_STEPS :: 25
@(private = "file")
EFFECT_QUEUE :: 8

@(private = "file")
Yukes_Effect :: struct {
	core:             int,
	mode:             u32,
	depth_l, depth_r: i16,
}

@(private = "file")
yukes_effect: struct {
	queue:  [EFFECT_QUEUE]Yukes_Effect,
	n:      int,
	step:   int, // of the change at queue[0], 0 ..< 2*EFFECT_STEPS
	from_l: i16, // the depth when it started
	from_r: i16,
	depth:  [CORES][2]i16, // EVOLL and EVOLR as last set
	mode:   [CORES]u32, // the mode running, kept through the ramp down
}

// 0x6c: queue a change. A full queue drops it; the game makes two at a time.
@(private = "file")
yukes_effect_queue :: proc(w: [^]u32) {
	h := ([^]u16)(w)
	e := Yukes_Effect{int(w[8]), w[13], i16(h[0x1c]), i16(h[0x1d])}
	if w[8] >= CORES || e.mode & 0xff > 9 || yukes_effect.n == EFFECT_QUEUE {
		fmt.eprintfln("yukes: effect core %d mode %x: not applied", w[8], e.mode)
		return
	}
	yukes_effect.queue[yukes_effect.n] = e
	yukes_effect.n += 1
}

// One step of the change at the head of the queue.
@(private = "file")
yukes_effect_tick :: proc() {
	fx := &yukes_effect
	if fx.n == 0 {return}
	e := fx.queue[0]
	d := &fx.depth[e.core]
	if fx.step == 0 {fx.from_l, fx.from_r = d[0], d[1]}
	if fx.step < EFFECT_STEPS {
		i := i32(EFFECT_STEPS - 1 - fx.step)
		d[0], d[1] = i16(i32(u16(fx.from_l)) * i / EFFECT_STEPS), i16(i32(u16(fx.from_r)) * i / EFFECT_STEPS)
		iop.spu_effect(e.core, fx.mode[e.core], d[0], d[1])
	} else {
		if fx.step == EFFECT_STEPS {
			fx.mode[e.core] = e.mode &~ 0x100
			iop.spu_effect_enable(e.core, false)
			iop.spu_effect(e.core, e.mode | 0x100, 0, 0)
			iop.spu_effect_enable(e.core, true)
			if cpu.debug >= 1 {
				fmt.eprintfln("yukes: effect core %d mode %x depth %x/%x enable on", e.core, e.mode, e.depth_l, e.depth_r)
			}
		}
		i := i32(fx.step - EFFECT_STEPS + 1)
		d[0], d[1] = i16(i32(u16(e.depth_l)) * i / EFFECT_STEPS), i16(i32(u16(e.depth_r)) * i / EFFECT_STEPS)
		iop.spu_effect(e.core, fx.mode[e.core], d[0], d[1])
	}
	fx.step += 1
	if fx.step < 2 * EFFECT_STEPS {return}
	fx.step = 0
	fx.n -= 1
	copy(fx.queue[:fx.n], fx.queue[1:fx.n + 1])
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
//   depth_R (16-bit), delay, feedback} at 0x30, for core core_no 0x20.
//   Its callback ignores the reply.
// 0x6d typespuCoreVolumeParam, 64 bytes at 0x395dc0 + 0x40*core (0x277650):
//   core_no 0x20, MVOLL 0x24, MVOLR 0x26, VOLL 0x28, VOLR 0x2a (16-bit;
//   the game sets all four to one value). VOLL is the master voice volume
//   key on scales by; MVOLL/MVOLR go to the core's SPU2 master volume.
// 0x67, 0x68 tagspuHDBDTrans: load and release sound bank n, 128 bytes at
//   0x395e40 + 0x80*n (0x2779b0, 0x277840): hd_ee 0x20, hd_iop 0x24,
//   hd_size 0x28, bd_ee 0x2c, bd_iop 0x30, bd_spu 0x34, bd_size 0x38,
//   trans_blocsize 0x3c, bank_index 0x40, bUsed 0x44, dma_ch 0x48. The bank
//   object (0x27a980) waits for thread_stat to read END_OK after a load and
//   for rpc_stat to read END after a release. The copy is done at once, so
//   both are reported done at once.
// 0x69 tagspuVoiceKeyTrans, 2368 bytes: nReq (0x920) key requests of 48
//   bytes from 0x20 (see Key). Its callback counts completions (0x398990).
@(private = "file")
yukes_301 :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool) {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x6a:
		yukes_report_addr = w[8]
		return true
	case 0x6c:
		yukes_effect_queue(w)
		return true
	case 0x6d:
		c := w[8]
		if c < CORES {
			yukes.master[c] = w[10] & 0xffff
			iop.spu_master(int(c), w[9] & 0xffff, w[9] >> 16)
		}
		return true
	case 0x67:
		yukes_load(w)
		w[YIOP_THREAD_STAT] = YIOP_THREAD_END_OK
		return true
	case 0x68:
		if w[0x10] < BANKS {yukes.loaded -= {int(w[0x10])}}
		w[YIOP_RPC_STAT] = YIOP_RPC_END
		return true
	case 0x69:
		n := min(w[0x920 / 4], (0x920 - 0x20) / KEY_SIZE)
		for i in 0 ..< n {
			yukes_request(buf[0x20 + i * KEY_SIZE:][:KEY_SIZE])
		}
		return true
	}
	return false
}

// EE RAM from addr, any mirror, clipped at its end.
@(private = "file")
ee_bytes :: proc(addr, size: u32) -> []u8 {
	a := addr & (mem.RAM_SIZE - 1)
	return mem.ram[a:][:min(size, mem.RAM_SIZE - a)]
}

// 0x67: bank n's HD into the module's table, its BD into sound RAM.
@(private = "file")
yukes_load :: proc(w: [^]u32) {
	n, hd_ee, hd_size, bd_ee, bd_spu, bd_size := w[0x10], w[8], w[10], w[11], w[13], w[14]
	if cpu.debug >= 1 {
		fmt.eprintfln("yukes: bank %d load hd %x+%x bd %x+%x to spu %x", n, hd_ee, hd_size, bd_ee, bd_size, bd_spu)
	}
	if n >= BANKS || hd_size > HD_MAX {
		fmt.eprintfln("yukes: bank %d hd size %x: not loaded", n, hd_size)
		return
	}
	b := &yukes.bank[n]
	b.hd = {}
	copy(b.hd[:], ee_bytes(hd_ee, hd_size))
	if string(b.hd[:8]) != "IECSsreV" || string(b.hd[0x10:0x18]) != "IECSdaeH" {
		fmt.eprintfln("yukes: bank %d at %x is not an HD", n, hd_ee)
		return
	}
	b.bd_spu = bd_spu
	iop.spu_write(bd_spu, ee_bytes(bd_ee, bd_size))
	yukes.loaded += {int(n)}
}

// Key, a tagspuVoiceKey: core 0, bank 4, pg_no 8, note_no 0xc, pitch
// (16-bit 4.12 multiplier) 0x10, velocity 0x14, voll and volr (signed
// 16-bit) 0x18 and 0x1a, pan 0x1c, command_target (16-bit) 0x20,
// command_func (16-bit) 0x22, voice_id 0x24, user_id 0x28.
@(private = "file")
Key :: struct {
	bank, pg, note, pitch, velocity: u32,
	voll, volr:                      i16,
	target, func, user:              u32,
}

@(private = "file")
key_parse :: proc(b: []u8) -> Key {
	w := ([^]u32)(raw_data(b))
	h := ([^]u16)(raw_data(b))
	return {
		bank = w[1],
		pg = w[2],
		note = w[3],
		pitch = u32(h[8]),
		velocity = w[5],
		voll = i16(h[12]),
		volr = i16(h[13]),
		target = u32(h[16]),
		func = u32(h[17]),
		user = w[10],
	}
}

// ysdhd_SetVoiceKeyTrans (0x2f58): command_func 0 key on, 1 key off by
// command_target (2 bank, 3 program, 5 user), 5 change volume, 6 pause,
// 7 continue. 2 to 4 do nothing.
@(private = "file")
yukes_request :: proc(b: []u8) {
	k := key_parse(b)
	switch k.func {
	case 0:
		yukes_key_on(k, b)
	case 1:
		yukes_key_off(k)
	case 5:
		yukes_change_volume(k)
	case 6:
		yukes_pause(k)
	case 7:
		yukes_continue(k)
	}
}

// Key off (ysdhdKeyOffBank, KeyOffPg, KeyOffUser): every voice whose key
// matches, idle or not, goes to release and forgets its key. An unused
// voice's key is zero, so it matches bank 0, program 0 or user 0.
@(private = "file")
yukes_key_off :: proc(k: Key) {
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			e := key_parse(yukes_key[c][v][:])
			match: bool
			switch k.target {
			case 2:
				match = e.bank == k.bank
			case 3:
				match = e.bank == k.bank && e.pg == k.pg
			case 5:
				match = e.user == k.user
			}
			if !match {continue}
			iop.spu_voice_off(c, v)
			yukes_key[c][v] = {}
		}
	}
}

// ysdhdKeyChangeVolume: sounding voices of the bank take voll and volr as
// the raw VOLL and VOLR.
@(private = "file")
yukes_change_volume :: proc(k: Key) {
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			if !voice_sounding(c, v) || key_parse(yukes_key[c][v][:]).bank != k.bank {continue}
			s := &yukes.voice[c][v]
			s.voll, s.volr = u32(u16(k.voll)), u32(u16(k.volr))
			iop.spu_voice_set(c, v, s.pitch, s.voll, s.volr)
		}
	}
}

// ysdhdKeyPause: the bank's voices stop at pitch 0, keeping the pitch the
// first pause found.
@(private = "file")
yukes_pause :: proc(k: Key) {
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			if key_parse(yukes_key[c][v][:]).bank != k.bank {continue}
			s := &yukes.voice[c][v]
			if !s.paused {
				s.last_pitch = s.pitch
				s.paused = true
			}
			s.pitch = 0
			iop.spu_voice_set(c, v, s.pitch, s.voll, s.volr)
		}
	}
}

// ysdhdKeyContinue: UpdateMasterVoiceVolume (0x1250) rescales every
// sounding voice, then every voice of the bank, paused or not, gets the
// pitch its last pause saved (0 if it never paused), as the module does.
@(private = "file")
yukes_continue :: proc(k: Key) {
	yukes_master_volume()
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			if key_parse(yukes_key[c][v][:]).bank != k.bank {continue}
			s := &yukes.voice[c][v]
			s.pitch = s.last_pitch
			s.paused = false
			iop.spu_voice_set(c, v, s.pitch, s.voll, s.volr)
		}
	}
}

// UpdateMasterVoiceVolume: every sounding voice's volume again from its key,
// with the key's own velocity (not the scaled one key on used) and core 0's
// master volume for both cores, as the module does.
@(private = "file")
yukes_master_volume :: proc() {
	for c in 0 ..< CORES {
		for v in 0 ..< VOICES {
			if !voice_sounding(c, v) {continue}
			e := key_parse(yukes_key[c][v][:])
			s := &yukes.voice[c][v]
			s.voll = voice_volume(e.voll, e.velocity, yukes.master[0])
			s.volr = voice_volume(e.volr, e.velocity, yukes.master[0])
			iop.spu_voice_set(c, v, s.pitch, s.voll, s.volr)
		}
	}
}

// A VOLL or VOLR value: |vol|/128 scaled by velocity (0..127) and the master
// volume (0..0x3fff). A negative vol gives the 15-bit negation, phase
// inverted, with bit 15 (sweep) clear.
@(private = "file")
voice_volume :: proc(vol: i16, velocity, master: u32) -> u32 {
	mag := u32(u16(vol < 0 ? -vol : vol)) >> 7
	x := mag * velocity * master / 0x3fff & 0xffff
	return vol < 0 ? (0 - x) & 0x7fff : x
}

// sdhd's HD v3 chunks, by their offset field in the header ("IECSdaeH" at
// bank +0x10); each holds offsets to its entries (0xffffffff: none).
@(private = "file")
HD_PROG :: 0x14
@(private = "file")
HD_SSET :: 0x18
@(private = "file")
HD_SMPL :: 0x1c
@(private = "file")
HD_VAGI :: 0x20

@(private = "file")
hd_u8 :: proc(hd: []u8, o: u32) -> u32 {
	return o < u32(len(hd)) ? u32(hd[o]) : 0
}

@(private = "file")
hd_u16 :: proc(hd: []u8, o: u32) -> u32 {
	return hd_u8(hd, o) | hd_u8(hd, o + 1) << 8
}

@(private = "file")
hd_u32 :: proc(hd: []u8, o: u32) -> u32 {
	return hd_u16(hd, o) | hd_u16(hd, o + 2) << 16
}

// Entry i of a chunk, as an offset in hd.
@(private = "file")
hd_entry :: proc(hd: []u8, chunk, i: u32) -> (off: u32, ok: bool) {
	c := hd_u32(hd, 0x10 + chunk)
	if c >= u32(len(hd)) || i > hd_u32(hd, c + 0xc) {return}
	e := hd_u32(hd, c + 0x10 + 4 * i)
	if e == 0xffffffff || c + e >= u32(len(hd)) {return}
	return c + e, true
}

// One voice to key on, what ysdhdGetKeyOnParam keeps per sample: velocity
// (0..127) is the request's scaled by the sample's and the program's
// volumes; base note, detune and envelope are the sample's, the VAG offset
// in the BD and its rate the VAG info's, transpose the split's.
@(private = "file")
Key_On :: struct {
	core, voice:        int,
	velocity:           u32,
	base_note, detune:  u32,
	adsr1, adsr2:       u32,
	vag_offset, rate:   u32,
	transpose:          i8,
}

// ysdhdGetKeyOnParam (0x422c), set_voiceNumber (0x369c) and key_on
// (0x3800): one voice per sample of every split of the program that holds
// the note and every sample of its sample set that holds the velocity. No
// voice keys on unless every sample finds a free one.
@(private = "file")
yukes_key_on :: proc(k: Key, raw: []u8) {
	if k.bank >= BANKS || int(k.bank) not_in yukes.loaded {return}
	b := &yukes.bank[k.bank]
	hd := b.hd[:]
	prog, ok := hd_entry(hd, HD_PROG, k.pg)
	if !ok {return}
	ons: [CORES * VOICES]Key_On
	n := 0
	splits, nsplit, size := prog + hd_u32(hd, prog), hd_u8(hd, prog + 4), hd_u8(hd, prog + 5)
	for s in 0 ..< nsplit {
		n = key_on_split(hd, k, hd_u8(hd, prog + 6), splits + s * size, ons[:], n)
	}
	if n == 0 || !key_on_assign(ons[:n]) {return}
	for on in ons[:n] {
		key_on_voice(b, k, raw, on)
	}
}

// The samples split sp adds for the request, from ons[n]; returns the new n.
// The split and sample range checks honour only bits 0..6, and the fades
// bit 7 enables (cal_velRangeEffect, cal_splitRangeEffect) are not done:
// no bank sets it.
@(private = "file")
key_on_split :: proc(hd: []u8, k: Key, prog_vol, sp: u32, ons: []Key_On, n: int) -> int {
	n := n
	if k.note < hd_u8(hd, sp + 2) & 0x7f || k.note > hd_u8(hd, sp + 4) & 0x7f {return n}
	sset, ok := hd_entry(hd, HD_SSET, hd_u16(hd, sp))
	// The sample set's own velocity range (sdhd 0xb78), unmasked.
	if !ok || k.velocity < hd_u8(hd, sset + 1) || k.velocity > hd_u8(hd, sset + 2) {return n}
	for i in 0 ..< hd_u8(hd, sset + 3) {
		smp, sok := hd_entry(hd, HD_SMPL, hd_u16(hd, sset + 4 + 2 * i))
		if !sok || k.velocity < hd_u8(hd, smp + 2) & 0x7f || k.velocity > hd_u8(hd, smp + 4) & 0x7f {continue}
		vag, vok := hd_entry(hd, HD_VAGI, hd_u16(hd, smp))
		vel := k.velocity * hd_u8(hd, smp + 0x10) * prog_vol >> 14
		if !vok || k.velocity == 0 || vel == 0 || n == len(ons) {continue}
		ons[n] = {
			velocity   = vel,
			base_note  = hd_u8(hd, smp + 0xb),
			detune     = u32(u16(i16(i8(hd_u8(hd, smp + 0xc))))),
			adsr1      = hd_u16(hd, smp + 0x12),
			adsr2      = hd_u16(hd, smp + 0x14),
			vag_offset = hd_u32(hd, vag),
			rate       = hd_u16(hd, vag + 4),
			transpose  = i8(hd_u8(hd, sp + 0x12)),
		}
		n += 1
	}
	return n
}

// The module's "sounding" test, ENVX not 0, plus a voice keyed on since
// the last mix.
@(private = "file")
voice_sounding :: proc(c, v: int) -> bool {
	return v in yukes.fresh[c] || iop.spu_voice_status(c, v).envx != 0
}

// set_voiceNumber: each in turn takes the first voice, core 0 then core 1,
// whose envelope is at zero and that none before it took.
@(private = "file")
key_on_assign :: proc(ons: []Key_On) -> bool {
	taken: [CORES][VOICES]bool
	for &on in ons {
		found := false
		scan: for c in 0 ..< CORES {
			for v in 0 ..< VOICES {
				if taken[c][v] || voice_sounding(c, v) {continue}
				taken[c][v] = true
				on.core, on.voice = c, v
				found = true
				break scan
			}
		}
		if !found {return false}
	}
	return true
}

// key_on, one voice: pitch from the note against the sample's base note,
// times the request's pitch, times the VAG's rate over 48 kHz.
@(private = "file")
key_on_voice :: proc(b: ^Yukes_Bank, k: Key, raw: []u8, on: Key_On) {
	note := u32(u16(i16(k.note) + i16(on.transpose)))
	pitch := min(note_to_pitch(on.base_note, on.detune, note, 0), 0x3fff)
	pitch = min(pitch * k.pitch >> 12, 0x3fff)
	pitch = u32(i32(pitch * on.rate) / 48000) & 0x3fff
	s := &yukes.voice[on.core][on.voice]
	s.pitch = pitch
	s.voll = voice_volume(k.voll, on.velocity, yukes.master[on.core])
	s.volr = voice_volume(k.volr, on.velocity, yukes.master[on.core])
	iop.spu_voice_on(on.core, on.voice, {
		ssa = b.bd_spu + on.vag_offset,
		pitch = s.pitch,
		voll = s.voll,
		volr = s.volr,
		adsr1 = on.adsr1,
		adsr2 = on.adsr2,
	})
	copy(yukes_key[on.core][on.voice][:], raw)
	yukes.fresh[on.core] += {on.voice}
}

@(private = "file")
NOTE_TAB := [12]u32{0x8000, 0x879c, 0x8fac, 0x9837, 0xa145, 0xaadc, 0xb504, 0xbfc8, 0xcb2f, 0xd744, 0xe411, 0xf1a1}

@(private = "file")
FINE_TAB := [128]u32 {
	0x8000, 0x800e, 0x801d, 0x802c, 0x803b, 0x804a, 0x8058, 0x8067,
	0x8076, 0x8085, 0x8094, 0x80a3, 0x80b1, 0x80c0, 0x80cf, 0x80de,
	0x80ed, 0x80fc, 0x810b, 0x811a, 0x8129, 0x8138, 0x8146, 0x8155,
	0x8164, 0x8173, 0x8182, 0x8191, 0x81a0, 0x81af, 0x81be, 0x81cd,
	0x81dc, 0x81eb, 0x81fa, 0x8209, 0x8218, 0x8227, 0x8236, 0x8245,
	0x8254, 0x8263, 0x8272, 0x8282, 0x8291, 0x82a0, 0x82af, 0x82be,
	0x82cd, 0x82dc, 0x82eb, 0x82fa, 0x830a, 0x8319, 0x8328, 0x8337,
	0x8346, 0x8355, 0x8364, 0x8374, 0x8383, 0x8392, 0x83a1, 0x83b0,
	0x83c0, 0x83cf, 0x83de, 0x83ed, 0x83fd, 0x840c, 0x841b, 0x842a,
	0x843a, 0x8449, 0x8458, 0x8468, 0x8477, 0x8486, 0x8495, 0x84a5,
	0x84b4, 0x84c3, 0x84d3, 0x84e2, 0x84f1, 0x8501, 0x8510, 0x8520,
	0x852f, 0x853e, 0x854e, 0x855d, 0x856d, 0x857c, 0x858b, 0x859b,
	0x85aa, 0x85ba, 0x85c9, 0x85d9, 0x85e8, 0x85f8, 0x8607, 0x8617,
	0x8626, 0x8636, 0x8645, 0x8655, 0x8664, 0x8674, 0x8683, 0x8693,
	0x86a2, 0x86b2, 0x86c1, 0x86d1, 0x86e0, 0x86f0, 0x8700, 0x870f,
	0x871f, 0x872e, 0x873e, 0x874e, 0x875d, 0x876d, 0x877d, 0x878c,
}

// libsd's sceSdNote2Pitch (export 13): a 4.12 pitch for note against
// center_note, fine and center_fine in 1/128 semitones. Two octaves up and
// higher all give the two-octave pitch, as in libsd. The fine sum is
// unsigned here (center_fine is a u16 and the callers pass fine 0), which
// leaves out libsd's negative-fine path.
@(private = "file")
note_to_pitch :: proc(center_note, center_fine, note, fine: u32) -> u32 {
	ft := i32(i16(u16(fine))) + i32(u16(center_fine))
	q := ft >> 7
	n := i32(i16(i32(note) + q - i32(center_note)))
	o := n / 12
	r := n - o * 12
	sh := o - 2
	if r < 0 {
		r += 12
		sh = o - 3
	}
	ret := NOTE_TAB[r] * FINE_TAB[ft & 0x7f] >> 16
	if sh < 0 {
		s := u32(-sh)
		ret = (ret + (1 << (s - 1))) >> s
	}
	return ret & 0xffff
}
