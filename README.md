# Berserk – Millennium Falcon on ps-recomp

A native port of *Berserk – Millennium Falcon Hen: Seima Senki no Shō*
(PS2, NTSC-J, SLPM_656.88) with the English v1.1 fan translation applied,
built by statically recompiling the game's executable with
[ps-recomp](https://github.com/plaught-armor/ps-recomp).

This repository holds no game data. You build the port from a disc you own.

## Status

- Tested on Linux only.
- **No sound.** The game's own sound and streaming module (Yukes, IOP RPC
  0x300/0x301) and CRI ADX are stubbed, so music, voice and effects are
  silent.
- Boots through the title screen into the first stage. Later stages have not
  been played through on the port yet.

## Requirements

- Odin `dev-2026-10`
- SDL2 and Vulkan 1.3
- ps-recomp at commit `6cb6c70` (the last one this port was tested against)
- A dump of the disc with the English v1.1 patch applied

## 1. Extract the disc

Put the disc's files in `disc/` at the repository root, for example from an
ISO image:

```sh
7z x -odisc "Berserk - Millennium Falcon (English v1.1).iso"
```

`disc/` should then contain `SLPM_656.88`, `SYSTEM.CNF`, `PACLIST.H` and the
`BGM/`, `MODULE/`, `MOVIE/`, `PAC/` and `VOICE/` directories. The code ranges
in `tools/` are specific to the patched executable:

```
411b14985eaeb4388c80012ce2567577d09a05a245a463d5f327661658eac8f5  disc/SLPM_656.88
```

## 2. Recompile the executable

Build ps-recomp's recompiler, then run it from this repository's root with
`tools/recomp.tsv`. It writes the generated Odin code to `port/src/rec/`.

```sh
(cd <ps-recomp> && odin build recomp -collection:ps=. -o:speed -out:recomp-bin)
<ps-recomp>/recomp-bin tools/recomp.tsv
```

On a first build you have no VU1 capture yet (see step 5): comment out the
`vu1_capture` line in `tools/recomp.tsv` until `port/vu1.cap` exists.

## 3. Build the port

```sh
odin build port/src -collection:ps=<ps-recomp> -define:ENV_PREFIX=GAME_ \
	-use-separate-modules -o:speed -out:berserk
```

## 4. Run

```sh
./berserk disc
```

The disc directory defaults to `disc`. Memory cards are saved to
`memcard0/` and `memcard1/` in the current directory, or under `GAME_MC`
if set.

## 5. Optional: capture VU1 microcode

Some of the game's VU1 microprograms are built at run time from data, so the
recompiler can only find them by watching the game run. Without a capture
they run in the VU interpreter: correct, but slower.

Play with capture on (everything VU1 runs in the interpreter while
capturing, so this pass is slow), then repeat steps 2 and 3 with the
`vu1_capture` line enabled:

```sh
GAME_VU1_CAPTURE=port/vu1.cap ./berserk disc
```

Runs append to the file, so several sessions covering different parts of the
game can share one capture. The capture contains the game's microcode and is
not committed.

## Layout

| Path | Contents |
|---|---|
| `port/src/main.odin` | Entry point: loads the executable from the disc and starts the runtime |
| `port/src/yukes.odin` | HLE stub for the game's Yukes IOP module |
| `tools/recomp.tsv` | Recompiler options |
| `tools/code_ranges.tsv`, `tools/README.md` | Where the code is in SLPM_656.88, and why |
