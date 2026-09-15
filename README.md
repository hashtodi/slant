# Slant

**Your desktop leans with the lid.** Close your MacBook and the screen tilts back, softens, and goes quiet — sharp at the hinge, blurring toward the top, the way a folding screen actually behaves.

![Slant folding the desktop as the lid closes](docs/demo.gif)

[Full-quality video](docs/demo.mp4)

- Reads the hinge angle in **hundredths of a degree**, 120 times a second
- A critically damped spring that **stiffens as you move faster**, so it tracks your hand at any speed and settles without a bounce
- True perspective through a projective transform — not a squeeze
- **The picture stays intact at the hinge**, exactly as it does at the crease of a folding phone
- Learns where you rest your lid, so there is no angle to configure
- Sleeps when the lid does. No measurable cost while you work

## Run it

Slant is not notarised, so there is no download — you build it, which takes about
a minute and needs nothing but a Mac.

```bash
git clone https://github.com/hashtodi/slant.git
cd slant
make go
```

`make go` builds Slant, puts it in `/Applications`, and opens the one settings
pane macOS will not let an app open for itself. Grant Screen Recording there,
then:

```bash
make start
```

Close the lid slowly. Slant lives in the menu bar — no Dock icon. `make stop`
quits it.

### The permission, and why it is fiddly

Slant needs **Screen Recording** to see the desktop it is folding. Nothing is
recorded: frames go from the display to the GPU, are never written to disk, and
never leave your Mac.

Two things macOS will not tell you, both consequences of Slant being unsigned:

- **The grant is keyed to the exact build.** Rebuild Slant and the old entry in
  that list goes stale. **Remove it with the − button and add it again** —
  toggling it off and on does not work.
- **Launch it with `make start`, not by running the binary.** macOS attributes
  the permission to whichever process started it, so running the executable from
  a shell asks on the terminal's behalf and gets refused no matter how many times
  you grant it.

Paying Apple 99 USD a year for a Developer ID would end both of these. If enough
people want this, that is the first thing the money goes to.

## Requirements

macOS 14 or later, on an **Apple silicon MacBook with a lid-angle sensor**.

The sensor arrived with the 2019 16-inch MacBook Pro. It is **not present on the M1 MacBook Air, or the M1 and M2 13-inch MacBook Pro**. Slant cannot run on those, and no software can substitute for missing hardware. Rather than failing silently, Slant tells you which of two reasons applies: no sensor at all, or a sensor that macOS exposes on a page it cannot be read from.

The effect applies to the built-in display only. External displays are left alone.

## Building on it

```bash
make build      # produces .build/Slant.app
make install    # copies it to /Applications
make test       # 2100+ checks, no Xcode needed
make stop       # quit a running copy
```

**Xcode is not required.** The Metal shader is compiled at runtime from
`Sources/FoldRenderer/Fold.metal`, shipped as a bundle resource, so the Command
Line Tools are enough. The tests are a plain executable with a hand-rolled
harness in `Sources/TestKit` — no XCTest, no swift-testing.

The fold's geometry is checked against frame-accurate measurements of a real
MacBook closing: visible height `sin θ`, side taper `1 − s·cos θ / d`, full width
at the hinge. If you change the model, those tests are what tell you whether you
have broken the thing that makes it look right.

### Tuning

Every constant in the look is readable from the environment, so the feel can be
changed without rebuilding:

| Variable | Default | What it does |
|---|---|---|
| `SLANT_EYE_DISTANCE` | 3.8 | viewer distance, in screen heights (sets the side taper only) |
| `SLANT_EYE_LEVEL` | 1 | assumed viewpoint, as a fraction of the panel top edge (1 = level with it) |
| `SLANT_MODEL` | pinned | `pinned`, `flat` (no magnification, cut at sin θ) or `warp` | `warp` (hinge's trapezoid, nothing cropped) or `pinned` (upright snapshot, cut from the top) |
| `SLANT_TAPER` | 0.30 | how far the top edge draws in, warp model only |
| `SLANT_BLUR` | 90 | blur radius at full fold, in source pixels |
| `SLANT_DIM` | 0.5 | darkening at full fold |
| `SLANT_BLUR_CURVE` | 0.5 | how late blur builds |
| `SLANT_DIM_CURVE` | 0.7 | how early darkening arrives |
| `SLANT_RIM` | 0 | soft rim on the exposed sides, as a share of the wedge |
| `SLANT_HINGE_BLUR` | 0.02 | blur surviving at the hinge edge |
| `SLANT_HINGE_DIM` | 0.10 | darkening surviving at the hinge edge |
| `SLANT_DEADZONE` | 8 | degrees below your resting angle before anything happens |
| `SLANT_FULL_ANGLE` | 30 | angle at which the fold is complete |
| `SLANT_START_CEILING` | 88 | the effect never begins above this angle |
| `SLANT_DEMO` | — | set to 1 to drive the fold from a timer with the lid open |

`SLANT_DEMO=1` exists because the effect cannot be screen-recorded any other
way: the display sleeps as the lid shuts, so a recording of a real close
captures nothing.

## How it works

The lid angle arrives over IOHID as a feature report. Most implementations read
report 1, which carries whole degrees and then needs heavy filtering to hide the
stair-stepping. Slant probes **report 7** first, which carries hundredths of a
degree, and falls back to report 1 only if the hardware does not answer.

That angle drives a spring, the spring drives a fold amount, and the fold amount
drives a projective transform. The desktop is captured once through
ScreenCaptureKit and **frozen for the duration of a fold** — the desktop cannot
change while the lid is closing, and a still image removes both the possibility
of the overlay appearing in its own capture and any beat frequency between
capture and render rates.

Blur costs nothing: a Gaussian pyramid is built once per fold and sampled at a
continuous mip level, shaped so it is strongest at the top edge and weakest at
the hinge.

## Thanks

The lid-angle HID interface was reverse-engineered by
[Sam Henri Gold's LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor).
The homography and mip-pyramid rendering approach, the hundredths-of-a-degree
report, and the ScreenCaptureKit presence-window technique come from
[sumimakito's Mac-Duo](https://github.com/sumimakito/Mac-Duo). Both are
Apache-2.0. Ideas were also studied in
[hinge](https://github.com/noveum/hinge) and
[Dhananjay Bhosale's MacDuo](https://github.com/DhananjayBhosale/MacDuo).

See [NOTICE](NOTICE) for the full attribution.

## Licence

MIT. See [LICENSE](LICENSE).

Slant is not affiliated with, endorsed by, or connected to Apple Inc.
