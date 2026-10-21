# ExoShelf

A native macOS launcher for [eXo's](https://www.retro-exo.com) collections of
preconfigured games. Browse and search each catalogue with its box art,
download only the games you want, and play them under
[DOSBox Staging](https://www.dosbox-staging.org) or
[ScummVM](https://www.scummvm.org). Written in Swift and SwiftUI, with no
third-party dependencies.

## Supported collections

| collection | games | runs under | torrent |
|---|---|---|---|
| [eXoDOS](https://www.retro-exo.com/exodos.html) | 7,666 DOS games | DOSBox Staging | 698 GB |
| [eXoWin3x](https://www.retro-exo.com/win3x.html) | 1,139 Windows 3.x games | DOSBox Staging, each in its own Windows 3.1 | 371 GB |
| [eXoScummVM](https://www.retro-exo.com/scummvm.html) | 832 adventure games | ScummVM, in the version eXo pins each game to | 284 GB |

Set up any or all of them; each has its own shelf, and search can span them
all. eXoWin9x and the language packs are not supported.

Each collection ships as one huge torrent with a Windows-only LaunchBox front
end. ExoShelf never downloads the whole thing. It carries its own small
BitTorrent client that fetches individual files, and individual *byte ranges*
of files, straight out of eXo's official torrents. For eXoDOS:

- the catalogue (`MS-DOS.xml`, 37 MB) and the box-art index come out of the
  5.3 GB `XODOSMetadata.zip` by reading only its directory and one entry, about
  25 MB in all;
- each cover is one entry of that same archive, fetched when it scrolls into
  view; the other covers in the same 8 MB piece come with it;
- a game is its own zip under `eXo/eXoDOS/`, downloaded, verified piece by
  piece, and unpacked where eXo's configs expect it;
- eXo's per-game DOSBox configs (`!DOSmetadata.zip`, 15 MB) and the MT-32 ROMs
  and SoundCanvas soundfont (a zip stored inside `util.zip`) are fetched once,
  before the first game.

eXoWin3x works the same way, except that its config archive is 680 MB of
mostly manuals, so each game's launch files are read out of it in place.
eXoScummVM needs no per-game configs at all: eXo's launch index
(`scummvm.txt`, 64 KB, inside the 1 GB `utilSVM.zip`) names each game's engine
and ScummVM build. The MT-32 files are the same in all three and are fetched
once, by whichever collection needs them first.

ExoShelf hosts nothing and bundles none of eXo's data. Everything comes from
eXo's torrents. If you get value out of it, support
[the eXo projects](https://www.retro-exo.com).

Requirements: macOS 15 or later, a Swift 6.2 toolchain (Xcode 26 or later) to
build, DOSBox Staging, which the app can install for you, and for eXoScummVM
the official ScummVM releases, which it installs as games need them.

## Quick start

```bash
make install
```

This builds `ExoShelf.app` and copies it into `~/Applications`. On first
launch, pick a games folder (default `~/Games/ExoShelf`), tick the
collections you want and press **Set Up**; each catalogue is ready in about
twenty seconds. Collections left out can be set up later: pick one in the
sidebar's collection menu. If DOSBox Staging is missing, **Install** next to
it puts the latest official release into `~/Applications`.

Then search, select a game and press **Download**. Double-click a cover, or
press ⌘↩, to play.

## Building with make

| target | what it does |
|---|---|
| `make build` | debug build of the app and the CLI |
| `make test` | unit tests (no network) |
| `make app` | assemble and ad-hoc sign `build/ExoShelf.app` |
| `make run` | build the app and open it |
| `make install` | copy the app into `~/Applications` (`APPDIR=` to change) |
| `make install-cli` | copy `exoshelf-cli` into `/usr/local/bin` (`PREFIX=` to change) |
| `make uninstall` | remove the app and CLI; your games stay |

## The app

- **Collections**: the menu at the top of the sidebar switches between eXoDOS,
  eXoWin3x and eXoScummVM, and offers to set up the ones that are not yet.
- **Library**: all games, installed, favourites, recently played, plus eXo's
  feature lists (Roland MT-32, Sound Canvas, Gravis Ultrasound, 3dfx, CGA
  composite, PCjr, remote multiplayer), decades and genres.
- **Search**: every word must match title, developer, publisher, genre, series
  or year; punctuation and accents are ignored, so `kings quest 1984` works.
  The scope bar under the search field widens it to all collections.
- **Grid or list** (⌘1, ⌘2), with sort by title, year, developer or rating.
- **Detail**: box art, eXo's description, screenshots, size, and the game's
  alternative configurations where eXo offers them (EGA or CGA, sound cards;
  for ScummVM, each edition, version and music choice of eXo's menus). The
  choice is remembered per game.
- **Downloads** resume after a quit: finished pieces are recorded next to the
  partial file.
- **Graphics** (⌥⌘G for the selected game): upscaling and display, as a
  default for every game in Settings → Graphics and per game from the
  detail view; see below.
- **Settings**: games folder, keep archives after unpacking, the emulators
  (including a ScummVM of your own in place of eXo's pinned releases), full
  screen, graphics, and how General MIDI is played.

## Graphics

Every game can be upscaled. The default is Staging's sharp pixel scaling, the
closest to eXo's own setup; a game with its own settings shows a filled TV
icon in its detail view.

| family | styles |
|---|---|
| pixels | sharp pixels, nearest neighbour |
| pixel-art upscalers | xBR (LV3), xBR without blending, xBR 3D, Scale3x (AdvMAME), AdvInterp/HQ |
| smoothing | Catmull-Rom, bilinear |
| CRT monitor | Staging's adaptive CRT, CRT for the emulated card, arcade, arcade sharp |

Alongside the upscaler: aspect ratio (4:3, square pixels, stretch), integer
scaling, window size, dedithering (blends CGA/EGA checkerboard dithering into
solid colour), deinterlacing for interlaced video scenes, CRT colour profiles
(EBU, P22, SMPTE-C, Philips, Trinitron), the CGA palette (canonical, DGA16,
Tandy, IBM 5153) and the monochrome monitor (amber, green, white, paperwhite).

DOSBox Staging gets these as config settings after eXo's own; the launch
drops eXo's `glshader` and `windowresolution` lines first, because Staging
applies those deprecated keys after every config file and they would win.
ScummVM gets its nearest equivalents on the command line: Edge for xBR,
AdvMAME for Scale3x, HQ for AdvInterp, TV for the CRT styles, filtering for
the smoothing ones, with a 2×–4× scale factor each scaler caps at what it
supports. "As configured" leaves everything to eXo and your emulator defaults.

## Command line

The same engine, without a window:

```bash
exoshelf-cli setup
exoshelf-cli setup eXoScummVM
exoshelf-cli collections
exoshelf-cli search dune
exoshelf-cli info "dune ii"
exoshelf-cli install dune2
exoshelf-cli play dune2
exoshelf-cli play dune2 --upscale=xbr
exoshelf-cli play "eXoScummVM/maniac mansion"
```

A game is named by title, shortcode or id, optionally behind its collection
(`eXoWin3x/3dmaze`); search covers every collection set up. `exoshelf-cli help`
lists the rest, including `upscalers` (the `--upscale` styles),
`install-scummvm` and `zipls`/`zipget`, which read
any zip inside a torrent (`eXo/util/util.zip::EXTDOS.zip` for a nested one).
`EXOSHELF_LIBRARY`, `EXOSHELF_SUPPORT` and `EXOSHELF_CACHES` override the
folders below, for the app as well; `EXOSHELF_DOSBOX` and `EXOSHELF_SCUMMVM`
name the emulators for the command line.

## How games run on a Mac

eXo's configs were written for Windows builds of DOSBox 0.74, DOSBox-ECE and
DOSBox Staging, run from the `eXo` folder with backslashed relative paths.
Before each launch ExoShelf writes a patched copy:

- `.\eXoDOS\DOOM` style **host** paths become absolute paths, but only when the
  file or folder exists on disk, because the same `.\` prefix also appears in
  guest-side DOS commands (`copy .\tandy\*.* .\`) that must stay as written;
- the game's own batch files get the same treatment, relative and with forward
  slashes, which is what makes eXo's multi-disc `run.bat` CD mounts work;
- ECE's `mt32.romdir` and `fluid.soundfont` keys become Staging's `[mt32]` and
  `[fluidsynth]` sections;
- General MIDI left to the system synth (`mididevice=default`, `auto`, or no
  device at all) goes to FluidSynth with eXo's SoundCanvas soundfont, since a
  Mac has no built-in GM synth. Choose *System MIDI port* in Settings for
  external hardware.

DOSBox Staging runs every game, including the ~2,100 eXo tuned for ECE and the
18 tuned for DOSBox-X. Your own Staging defaults load first, eXo's config
second and ExoShelf's settings last. Each game's DOSBox log is a menu item
away.

**eXoWin3x** games go through the same patching. Every game zip carries the
Windows 3.1 install eXo prepared for it, so a game folder is a complete C:
drive; Staging boots Windows straight into the game and quits with it. eXo's
catalogue spells the folder `eXoWin3X` in most rows and the torrent
`eXoWin3x`; ExoShelf uses the torrent's spelling, which matters on a
case-sensitive volume.

**eXoScummVM** games start the way eXo's `launch_svm.bat` starts them, without
its console menus:

- the edition (and version, where eXo has a sub-menu) and the music choice
  come from the detail view's menu, defaulting to the first entry of eXo's;
- eXo's launch index gives the engine and game id, and the build eXo pins it
  to: 2.8.0 for eXo's root build, 2.5.0, 2.9.0 or 2026.1.0 for the others,
  with the three git snapshots mapped to the release each grew into;
- that official release is installed from scummvm.org into ExoShelf's own
  folder, one per version, the first time a game needs it, and started with
  eXo's ini for the build;
- before that, `scummvm --detect` has to find the game in the edition's
  folder, so a damaged download is an error (the game's log has ScummVM's
  answer) instead of ScummVM's own launcher; this adds a second or two;
- where it finds the game several times, as in Level 9 trilogies whose parts
  are sibling files, one more `--detect` over each file alone says which is
  part 1, and that file starts as an `exoshelf-<id>` target in the build's
  ini: on APFS ScummVM would take whichever part the folder lists first;
- `platform.txt`, `video.txt`, `subtitle.txt` and the `audio.txt` files become
  ScummVM options, with eXo's platform codes translated (`sp48` is `zx`);
  MT-32 and Sound Canvas music use eXo's ROMs and soundfont;
- saved games go to `!saves` in the game's folder.

## Where things live

| path | contents |
|---|---|
| `~/Games/ExoShelf/eXo/` | games, configs and MT-32 files, in eXo's own layout (`eXoDOS/`, `eXoWin3x/`, `eXoScummVM/`, `mt32/`) |
| `~/Library/Application Support/ExoShelf/<collection>/` | torrent, catalogue, art index, library state, patched configs, logs |
| `~/Library/Application Support/ExoShelf/Emulators/` | the ScummVM releases ExoShelf installed |
| `~/Library/Caches/ExoShelf/` | piece cache (capped at 2 GB per collection) and cover thumbnails |

Versions before eXoWin3x and eXoScummVM kept eXoDOS's files at the top of the
Application Support folder; they move into `eXoDOS/` on the first start,
installs and favourites included.

## Known limits

- **Downloads only.** ExoShelf connects out to peers and never uploads. Please
  seed eXo's torrents from a regular client if you can.
- **Peer discovery** uses the torrent's trackers and peer exchange, not DHT.
  Peers that insist on protocol encryption cannot be reached. On eXoDOS this
  still means dozens of peers and several MB/s.
- **eXoWin9x and the language packs** are separate torrents with their own
  launch rules and are not supported yet.
- **eXoScummVM extras.** The "Other Languages" editions, which eXo hands to
  DREAMM, are not offered. Games eXo names without an engine (`wage`,
  `simo1`) pass the `--detect` check whenever ScummVM finds any game in the
  folder: its table names games as `engine:id`, which such a name cannot be
  matched against.
- **ECE extras.** Games that rely on DOSBox-ECE specials (3dfx tweaks, the
  GunStick light gun, printing) may behave differently under Staging.
- The app is ad-hoc signed by `make app`; it runs on the Mac that built it.

## Tests

`make test` runs the unit tests: bencode, torrent metadata and info hash, wire
messages, the zip reader (zip64, nested, deflate, CRC, path traversal), the
collections and LaunchBox parsing for each (eXoWin3x's folder spelling,
eXoScummVM archives that differ from the catalogue in case), box-art
matching, search, the move from the single-collection layout, config and
batch rewriting, MIDI translation, the graphics settings for both emulators,
and eXo's ScummVM launch index, edition
menus and command lines, `--detect`'s table, part numbers and the targets
that pin a first part. Nothing touches the network; the torrent client was
exercised against the live eXoDOS, eXoWin3x and eXoScummVM swarms through
`exoshelf-cli`.

## Thanks

[eXo](https://www.retro-exo.com) and the eXoDOS, eXoWin3x and eXoScummVM
contributors made the collections.
[Exodium](https://github.com/tvollstaedt/exodium), a cross-platform launcher
for them, documented many of the macOS launch pitfalls first, and the
eXoWin3x and eXoScummVM quirks above.

## License

MIT; see [LICENSE](LICENSE). eXo's collections and their games, art and
metadata belong to their respective owners and are not part of this
repository.
