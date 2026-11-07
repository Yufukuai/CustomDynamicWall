# How it works (findings)

## Where the player lives
On Sequoia there is no separate `WallpaperVideoCore` image in the dyld shared cache; it is **statically linked into**
`/System/Library/ExtensionKit/Extensions/WallpaperVideoExtension.appex`. `ipsw swift-dump --arch arm64e <that binary>` shows the types
(`ipsw` is not needed for anything in this repo):

```
enum WallpaperVideoCore.VideoSampleReadingErrors { noAssetReader, noSampleBuffer, noPixelBuffer, noTimeAdjustedSampleBuffer, noTemporalInfo }
struct WallpaperVideoCore.VideoSampleTSAInfo { temporalLevelNumber: Int?; isTSA: Bool; isSTSA: Bool }
enum WallpaperVideoCore.TSALevels { level15FPS, level30FPS, level60FPS, level120FPS, level240FPS }
class WallpaperVideoCore.VideoSampleReader { assetReader, assetReaderOutput, assetTrack, decompressionSession, frameRate, duration, greatestPTS … }
```
Swift error codes are zero-based case indexes, so **Code=4 is `noTemporalInfo`**. The player (`VideoPlayer`) keeps `rampUp/rampDown`
current/target `TSALevels` state — it drops and restores frame-rate layers when the presentation mode changes, which is why it works
on the first lock and breaks on unlock.

## What Apple's files have that a normal encode doesn't
Compared against Apple's 240 fps Aerial (`…_240fps_…_tsa.mov`, "tsa" = temporal sub-layer access):
- Every sample carries a CoreMedia `HEVCTemporalLevelInfo` attachment with `TemporalLevel` 0…4 (distribution 1/16, 1/16, 1/8, 1/4, 1/2).
- HEVC Main10, 3840×2160, 239.76 fps (`r_frame_rate=5994/25`), time base 1/239760 (**1000 ticks per frame**), first PTS 0, B-frames.
- Nothing in `entries.json` or `Aerial.sqlite` carries a duration, frame count or time range — only URLs and `pointsOfInterest` (shot-name keyed by offset).
  So an exact frame count/duration is **not** required.

## Producing it
VideoToolbox's HEVC encoder has (undocumented) properties `NumberOfTemporalLayers` and `BaseLayerFrameRate`. Setting them makes the encoder emit
`HEVCTemporalLevelInfo` on every sample. The hardware encoder gave 3 layers regardless of the requested count; the player accepts it.

Pitfalls that cost time (all handled in `aerialize.swift`):
1. `AVAssetWriterInput.mediaTimeScale` must be set to 239760, otherwise the MOV muxer rescales the track to 1/600 and frame times become uneven.
2. At timescale 239760, one frame is **1000 ticks**. Stamping frames 1 tick apart makes a 30 s clip last 30 ms; the wallpaper looks "frozen" and the log shows `minUpcomingOriginalPTS` creeping by 8 µs.
3. Check `r_frame_rate` — it must read `5994/25`, not `239760/1`.
4. Zero first PTS: sources with a start offset (e.g. 0.05 s) are shifted to 0.

## Registering it
`/Library/Application Support/com.apple.idleassetsd/Customer/entries.json` (assets, categories → subcategories) and `Aerial.sqlite`
(Core Data: `ZASSET`, `ZCATEGORY`, `ZSUBCATEGORY`, join tables `Z_1CATEGORIES`/`Z_1SUBCATEGORIES`, and `Z_PRIMARYKEY` bookkeeping; the asset's
`ZREMOTEURLS` / `ZPOINTSOFINTEREST` are NSKeyedArchiver blobs). The slot file is `Customer/4KSDR240FPS/<asset-id>.mov` and `file://` URLs must be
percent-encoded (`Application%20Support`). `catalog.py` generates both edits; the daemon runs as root, so the database edit needs sudo.

## Generalisation notes
- Slot folder name follows a rule seen in the catalog: `url-4K-SDR-240FPS` → `Customer/4KSDR240FPS/`. Only that one key exists on macOS 15.8.2; older/newer systems may differ.
- Frame timing generalises as Apple's: `timescale = fps × 1000`, 1000 ticks per frame (239.76 → 239760, 60 → 60000). Other fps values were verified for encode/verify consistency only, not for playback in the wallpaper.
- Scaling goes through `AVAssetReaderVideoCompositionOutput` (a plain track output crashes with width/height settings). Rotated sources are not handled.
- Failure modes are explicit: no temporal layers from the encoder → `encode` exits non-zero; `verify` fails any file lacking them.
