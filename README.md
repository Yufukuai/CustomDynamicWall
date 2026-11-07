# CustomDynamicWall

> why doesn't macOS let you do this out of the box?

Use **your own video** as a macOS Sequoia Aerial wallpaper / screen saver — one that **keeps playing after you unlock**.

Custom videos dropped into an Aerial slot typically play on the first lock, then freeze on unlock, with this in the log:

```
WallpaperVideoExtension: VideoPlayerLayer failed to acquire next sample due to error: VideoSampleReadingErrors Code=4
```

The cause (see [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)) is that Apple's Aerial files are HEVC with **temporal sub-layers** (15/30/60/120/240 fps) and the wallpaper player reads a per-frame temporal level so it can ramp the frame rate when the presentation mode changes (locked ↔ default). A normal encode has no such information. This repo re-encodes any video into that shape and registers it in Settings.

## Requirements
- Apple Silicon Mac, macOS 15 Sequoia, Xcode command line tools (`xcode-select --install`), `python3`, `sqlite3` (all stock apart from the CLT)
- A 3840×2160 source is expected. Other sizes still encode but may not suit the 4K slot.
- Admin rights (`sudo`) for the install step. **SIP stays enabled; nothing is injected or debugged.**

## Use
```sh
git clone git@github.com:Yufukuai/CustomDynamicWall.git && cd CustomDynamicWall
./install.sh install ~/Movies/my-video.mov "My Video"
```
Then open **System Settings → Wallpaper → Aerials → Custom → My Video**.

The installer: builds `aerialize`, checks whether your file already qualifies (otherwise re-encodes it: 10-bit HEVC, 239.76 fps, 5-layer-requested temporal scalability, ~30 Mbps; each source frame is repeated to reach 239.76 fps by timestamp so duration is preserved), **backs up** `entries.json` and `Aerial.sqlite` to `./backups/<timestamp>/`, installs the file + preview image, registers it, and restarts `idleassetsd` and the wallpaper extension.

Encoding runs on the Apple Silicon media engine at roughly 60 frames/s for 4K, i.e. about **4 minutes of encoding per minute of video** (measured: 6 min of video ≈ 24 min). Low CPU use is normal — the work isn't on the CPU cores.

Options: `--category NAME` (default `Custom`), `--mbps N`, `--seconds N` (encode only the first N seconds — good for a quick test), `--id UUID`.

```sh
./install.sh remove <UUID>      # removes the file, preview, entries.json and database rows (backs up first)
```

### Tools on their own
```sh
swiftc -O aerialize.swift -o aerialize
./aerialize verify file.mov                 # PASS/FAIL against the properties Apple's files have
./aerialize encode in.mov out.mov --seconds 10
./aerialize thumb  in.mov preview.jpg
```
`verify` is also a good way to diagnose a file that fails: it checks codec, bit depth, 239.76 fps, the 1/239760 timescale, first PTS = 0 and the temporal-level attachment on every sample.

## Caveats (please read)
- Verified on one machine (Apple Silicon, macOS 15.x, Darwin 24.6). The **lock → unlock behaviour was confirmed on the real machine** for a video encoded by `aerialize` and installed into a custom entry (whose database rows were renamed in place); the "register a brand-new entry" SQL in `catalog.py` was tested against copies of a real `Aerial.sqlite` (integrity check, structure matches existing custom rows) but the first-time insert path has not been exercised against a live daemon. Backups make it reversible.
- The hardware encoder produced **3** temporal layers (60/120/240 fps), not Apple's 5 (15…240). The player accepted that. Other Macs/OS versions may differ.
- A macOS update may overwrite `entries.json` or the database; just re-run `install.sh`.
- This edits files under `/Library/Application Support/com.apple.idleassetsd`. Use at your own risk; this is not affiliated with Apple.
