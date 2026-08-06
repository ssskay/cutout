# Cutout

Removes image backgrounds on your Mac. No account, no API key, no per-image cost,
and **no network access at all**.

Cutout uses Apple's Vision framework — the same subject-lifting model behind
Preview's "Remove Background" — so the model is already on your machine. Nothing
is uploaded, nothing is downloaded, and there is nothing to sign up for.

Built to replace remove.bg for two recurring jobs: eBay listing photos and
Singapore ICA ID photos.

## Offline by design, not by promise

The app ships sandboxed with **no `com.apple.security.network.*` entitlement**.
That is not a policy — it means macOS itself refuses to let Cutout open a network
connection. `scripts/release.sh` fails the build if a network entitlement ever
appears in the source entitlements *or* in the signed bundle, so it cannot creep
back in unnoticed.

## What it does

Drop one image or twenty. Each becomes a filmstrip entry; click one for a
before/after wipe preview. Pick a backdrop and a preset, choose an output folder,
export. Originals are never modified, and an existing file is never overwritten —
a name collision gets `-2`, `-3`, and so on.

If Vision cannot find a subject, that file fails loudly and is skipped. It will
never quietly export the untouched original. One failure does not stop a batch.

### Presets

| Preset | Output | Behaviour |
|---|---|---|
| Transparent PNG | PNG, source resolution | Cutout only, alpha preserved. For Glowforge and sticker art. |
| eBay listing | 1600 × 1600 JPEG, white | Subject centred at 90% of the frame, 5% padding. |
| ID photo (ICA) | 400 × 514 JPEG, white | Singapore ICA geometry — see below. |
| Custom | Your W × H | Same centring as eBay. |

### ID photos

The ICA spec is fussy and a rejection costs a week, so this preset shows its work
rather than asking you to trust it.

- 35 × 45 mm frame at 400 × 514 px.
- Crown-to-chin must land between 25 mm and 35 mm; Cutout targets **32 mm**.
- About 4 mm of headroom above the crown, face centred on the vertical midline.

The crown is found by scanning the alpha mask for the topmost row of subject
within the face's horizontal span — the mask already contains a clean hair
silhouette, which is far more reliable than extrapolating from Vision's face box
(that box stops at the forehead and ignores hair volume). The chin comes from
face landmarks where available, falling back to the face box.

**The computed head height in millimetres is shown in the UI**, alongside the
25–35 mm range, and turns orange when out of band. Sliders let you rescale and
nudge the crop before exporting. Auto-detection is a starting point, not a
verdict.

## Image quality

Two details make the difference between usable and not:

- **Mask resolution.** Vision's raw model output is only 512 × 512.
  `generateScaledMaskForImage` returns it already refined at full source
  resolution, which measurably beats upscaling the raw mask by hand — about 3×
  more anti-aliased edge detail on a hair-heavy test photo. Cutout keeps a
  Lanczos upscale as a fallback for the case where Vision ever returns an
  undersized mask.
- **Edge halo.** The mask is eroded slightly and then blurred under a pixel
  before compositing. Without it, a rim of original background pixels fringes the
  subject — glaring against pure white, which is exactly where these exports get
  used.

JPEGs are written at quality 1.0 through `CGImageDestination`, which is the only
combination on macOS that produces **4:4:4 chroma**. ImageIO silently drops to
4:2:0 at every lower quality setting and offers no key to decouple the two; 4:2:0
averages colour over 2 × 2 blocks and smears exactly the subject-against-white
edge these photos are viewed at. Cutout re-reads the JPEG's SOF marker after
writing and warns if the file did not come out 4:4:4.

## Logging

Every stage prints one structured line to stderr with its elapsed time:

```
cutout stage=load file=katie.jpg px=4032x3024 orientation=1 colorspace=kCGColorSpaceSRGB ms=41.6
cutout stage=mask file=katie.jpg instances=1 mask=4032x3024 src=4032x3024 upscaled=no ms=293.4
cutout stage=face file=katie.jpg faces=1 box=360,288,511x511 crown_y=76.00 chin_y=795.37 chin_src=landmarks crown_to_chin_px=719.37 target_mm=32.00 ms=131.5
cutout stage=write file=katie.jpg out=katie-id.jpg format=jpeg px=400x514 bytes=179624 quality=1.00 chroma=4:4:4 ms=5.1
```

When a crop looks wrong, the log says whether it was the mask or the face box
that lied.

## Requirements

macOS 14 or later. `VNGenerateForegroundInstanceMaskRequest` needs it.

## Install

Download the DMG from [Releases](https://github.com/ssskay/cutout/releases),
drag Cutout to Applications. It is signed and notarized, so it opens without a
Gatekeeper warning.

Verify the download if you like:

```bash
shasum -a 256 -c Cutout-macOS-1.0.0.dmg.sha256
```

## Development

```bash
open Cutout.xcodeproj
```

The engine also builds as a CLI so mask quality can be judged without the GUI.
It compiles the exact same `Cutout/Core/*.swift` files the app uses, so there is
no chance of testing a stale copy:

```bash
scripts/masktest.sh photo.jpg -o out --dump-mask
scripts/masktest.sh photo.jpg -o out --sweep      # erode/feather grid
scripts/masktest.sh photo.jpg -o out -p id        # ID preset with head-height readout
```

Cutting a release:

```bash
scripts/release.sh --dry-run     # build + sign, never contacts Apple
scripts/release.sh
```

The release script refuses to build with a beta Xcode. A beta Swift toolchain
miscompiled `MainActor` isolation across an `await`
([swiftlang/swift#89214](https://github.com/swiftlang/swift/issues/89214)) and
shipped a build of another app that crashed on every button tap.

## Licence

MIT — see [LICENSE](LICENSE).
