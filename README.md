# Berserk – Millennium Falcon on ps-recomp

A native port of *Berserk – Millennium Falcon Hen: Seima Senki no Shō*
(PS2, NTSC-J, SLPM_656.88) with the English v1.1 fan translation applied,
built by statically recompiling the game's executable with
[ps-recomp](https://github.com/plaught-armor/ps-recomp).

This repository holds no game data. You build the port from a disc you own.

## Status

- Tested on Linux only.
- Sound: music and the other CRI ADX streams (voice, movie audio) play.
  Sound effects play through a reimplementation of the game's own sound
  module (Yukes, IOP RPC 0x300/0x301): its HD/BD banks, key on and off,
  volume, pause and the reverb. The effect mix, delay and feedback values
  are not applied. Sound has only been checked as far as the first stage.
- Boots through the title screen into the first stage. Later stages have not
  been played through on the port yet.

## Requirements

- Odin `dev-2026-10` (84bc3fc21)
- SDL2 and Vulkan 1.3
- `7z` (p7zip) to unpack the disc image
- A dump of the disc with the English v1.1 patch applied

ps-recomp comes as a submodule pinned at the commit this port is tested
against. Clone with it:

```sh
git clone --recursive https://github.com/plaught-armor/berserk-recomp.git
cd berserk-recomp
# or, in an existing clone:
git submodule update --init
```

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
(cd ps-recomp && odin build recomp -collection:ps=. -o:speed -out:../recomp-bin)
./recomp-bin tools/recomp.tsv
```

`port/src/rec/` is a translation of the game's executable: it is ignored by
git and must never be committed or shared. Run this step again after
updating the ps-recomp submodule.

On a first build you have no VU1 capture yet (see step 5); the recompiler
warns about the missing `port/vu1.cap` and leaves that microcode to the VU
interpreter.

## 3. Build the port

```sh
odin build port/src -collection:ps=ps-recomp -define:ENV_PREFIX=GAME_ \
	-use-separate-modules -o:speed -out:berserk
```

## 4. Run

```sh
./berserk disc
```

The disc directory defaults to `disc`. Memory cards are saved to
`memcard0/` and `memcard1/` in the current directory, or under `GAME_MC`
if set.

### Optional: native x86-64 code

The recompiler can also emit x86-64 machine code, which runs faster than the
Odin build. Add these two lines to `tools/recomp.tsv` (separated by a tab)
and repeat step 2:

```
native_arch	x64_sysv
native_out	port/native_x64.bin
```

Then run with `GAME_NATIVE_FILE` naming the file, relative to the working
directory:

```sh
GAME_NATIVE_FILE=port/native_x64.bin ./berserk disc
```

Without it the Odin code runs. Like `port/src/rec/`, `port/native_x64.bin`
is generated from the game and is ignored by git.

## 5. Optional: capture VU1 microcode

Some of the game's VU1 microprograms are built at run time from data, so the
recompiler can only find them by watching the game run. Without a capture
they run in the VU interpreter: correct, but slower.

Play with capture on (everything VU1 runs in the interpreter while
capturing, so this pass is slow):

```sh
GAME_VU1_CAPTURE=port/vu1.cap ./berserk disc
```

Then repeat steps 2 and 3. `tools/recomp.tsv` already reads the capture
from `port/vu1.cap` through its `vu1_capture` line.

Runs append to the file, so several sessions covering different parts of the
game can share one capture. The capture contains the game's microcode and is
not committed.

## Layout

| Path | Contents |
|---|---|
| `port/src/main.odin` | Entry point: loads the executable from the disc and starts the runtime |
| `port/src/yukes.odin` | HLE of the game's Yukes IOP sound module |
| `tools/recomp.tsv` | Recompiler options |
| `tools/code_ranges.tsv`, `tools/README.md` | Where the code is in SLPM_656.88, and why |
| `tools/gate/` | Developer regression gate; tuned to the maintainer's machine, not needed to build or play |
| `ps-recomp/` | The ps-recomp submodule |

## License

GPL-3.0; see `LICENSE`. *Berserk – Millennium Falcon Hen: Seima Senki no
Shō* and its content belong to their respective owners; this project is not
affiliated with them.

The English text comes from the English v1.1 fan translation by
Wesker90. This repository does not include or distribute the
translation patch.
