# Slant — handoff

Paste this whole file as the first message in a new session.

---

## What this is

**Slant** — a macOS menu bar app that bends and blurs the desktop as the MacBook
lid closes, driven by the built-in lid-angle sensor.

Project root: `/Users/hashtodi/Desktop/side-project/duo-animation`
Git: repo initialised, branch `master`, **nothing committed yet**.
The user manages git themselves — never run git write commands. Suggest commit
messages instead.

**Context:** Apple announced the foldable "iPhone Duo" on 2026-09-09. Its fold
animation went viral and ~7 macOS clones appeared within 48 hours. Slant is a
late entrant whose intended edge is motion quality, honest failure messages, and
presentation — not features.

**Dev machine:** MacBook Pro `Mac16,8`, M4 Pro, macOS 26.2. Lid-angle sensor
present and working, answers HID feature **report 7** (hundredths of a degree).

---

## THE VISUAL MODEL — resolved, and how

Four attempts were rejected before the user supplied five frames of a reference
video (a real MacBook lid closing, fixed camera). Those frames were measured
rather than eyeballed, and they settled it.

**The model.** The desktop is nailed to a fixed rectangle in space — where the
screen stood at the reference angle — and the panel rotates out of that plane.
The panel is a window: for each pixel, follow the viewer's ray on to the pinned
plane and sample there. The picture never moves, never stretches, never
squeezes; the panel simply sees less of it. Width narrows from the top because
rays through the upper panel reach past the desktop's sides. It crops from the
top because those same rays land above it. The hinge row stays one to one.

**The measurements** (`Sources/SlantTests/FoldGeometryTests.swift` holds these
as assertions — the reference video is the regression suite):

| lid angle | 85° | 69.3° | 48.1° | 31.9° |
|---|---|---|---|---|
| visible width, relative to 85° | 1.000 | 0.921 | 0.806 | 0.737 |
| cut from the top | 0% | 0% | 11% | 35% |

These hold **at the tripod's viewpoint**, which is how the tests evaluate them
(`textureCorners(lidAngle:eyeDistance:eyeHeight:)`). They pin the model, not the
shipped defaults — see the eye-position note below.

Across those frames the panel's top edge splays 40% wider while the picture
grows 3.6% and its side edges stay vertical. Solving the projected panel height
recovers the camera — 2.97 screen heights away, 0.19 above the hinge, rms 0.0003
— and with it the lid angles above.

**Why the fourth attempt failed.** It was right. `SLANT_STRETCH` defaulted to 0,
which used the projection only as a visibility mask and sampled the texture at
the pixel's own coordinate — the picture glued to the panel, a shrinking black
aperture and no illusion. The flag is gone; the mask-only path was the bug.

**The height rule — this is the settled answer.** The visible fraction of the
picture's height is `sin(theta)`. A panel of height h tipped to theta stands
`h*sin(theta)` tall, so it covers an upright snapshot exactly that far and no
further: half the picture at 30 degrees. Nothing is done to the picture beyond
showing less of it.

In the existing ray machinery this is one substitution — the assumed eye sits
level with the **top edge of the panel**, `eyeHeight = sin(theta)`:

    V(top) = h + t*(sin(theta) - h)  ->  sin(theta) + t*0  =  sin(theta)

Eye distance drops out of the vertical entirely, which is the point: the
vertical no longer depends on a viewer position nobody can measure. The
horizontal taper depends only on distance (`U = t*u`, height cancels), so it
still comes from real perspective and the void wedges survive.

**What this cost, and why two earlier answers were wrong.** Filling the panel
with `sin(theta)` of the picture needs `1/sin(theta)` of vertical
magnification, which the panel's foreshortening returns: 1.13x at 75 degrees,
1.84x at 45, 2.79x at 30, and no angle where it blows up.

- Fitting the eye to the reference video (height 0.21, the tripod four
  centimetres above the hinge) gave almost no crop — 0.5% at 60 degrees — and
  the picture read as lying back at 100-120 degrees rather than standing at 90.
- Correcting that to a fixed seated eye (height 2.2) stood it up but demanded
  5x vertical magnification at 45 degrees and went singular at 36. The user's
  word for it was "pathetic", and the photo backed that up: dock icons three
  times their height.

A fixed eye is the mistake both times. The height rule has no fixed eye.

**The reference video's crop is gentler than this, and that is expected.** It
showed 89% of the picture's height at 48 degrees where `sin(48)` is 74%,
because it was filmed from a tripod at hinge level. `SLANT_EYE_LEVEL=0` returns
to that viewpoint if the gentler crop is ever wanted; 1 is the height rule.

**What the competitors settled (all 7 cloned and read).**

- Mac-Duo at its shipping defaults (`recession 1.0`, `startAngle 90`, eye at 6.0
  screen heights) has a visible source fraction that *is* `sin(theta)` — 0.5000
  at 30 degrees. The height rule is not a departure from the field; it ships.
- But the crop and the stretch are one fact. Showing `sin(theta)` of the source
  across a full panel *is* a `1/sin(theta)` magnification. Nobody removes it;
  five of seven never crop at all. "No vertical stretch" matches nothing.
- **Nobody corrects the stretch — they bury it in blur.** Max radii: Mac-Duo
  135, hinge ~139, jal-co up to 168, chuspeeism 72, Dhananjay 66. Slant shipped
  **20**. And DuoFlip, the only one with flat blur, has the worst anisotropy in
  the set. The gradients are load-bearing, not decorative.
- Eye distance converges on **4.5-6x the lever arm** across the three eye-based
  implementations (Mac-Duo 6.0, chuspeeism 5.0, jal-co 4.5). Slant had 3.05,
  which over-tapered; a measurement of the user's own screen photo independently
  said the same.
- Nobody has solved the viewpoint problem. Mac-Duo's README: "it's recommended
  to view the effect in front of your MacBook", plus a perspective slider.
- Apple's animation, per both recreations, uses `1 - d*sin(theta)/D` capped near
  20% compression, *not* `sin(theta)` — but both fold about a vertical hinge, so
  it does not transfer to a clamshell.

**Escape hatch if the pinned model keeps failing:** noveum/hinge (MIT) is the
whole effect in three lines of Metal — `q = (1+t*p)/(1+t*p*uv.y)`, `t = 0.30`,
no trigonometry, no eye, no crop, no void. Whole desktop to whole panel.

**Do not copy AresNing/DuoFlip.** No LICENSE; its README states public
visibility grants no license. Reference only.

**The full reference video was measured (24 frames of the closing phase),**
not just five stills. `MiZfJxANtpQfIHn2.mp4` in the project root; frames and the
detector live in the scratchpad. Results:

| | at rest | deepest measured |
|---|---|---|
| panel top edge, camera px | 555 | 870 (+57%) |
| picture width, camera px | 541 | 634 (+15%) |
| picture side slope | -0.04 | +0.03 |
| picture/panel at the hinge | 97% | 92-95% (the bezel) |
| picture/panel at the top | 97% | 72% |

The framebuffer taper equals `1/(panel splay)` to within 3% at every frame,
which is what "the picture does not move" means arithmetically. **It is the
pinned model, settled.** The warp model cannot express it — warp is
angle-independent and never crops, so it flatlines against all of this.

Fitted from it: `eyeDistance 3.2`, `eyeLevel 0.37`. Those reproduce the video's
taper and crop within 2% at every recovered angle, and a test at the shipping
defaults now holds them there.

**Two of the user's stated requirements contradict this footage.** Say so rather
than quietly picking one:

* *"Starts after maybe 75 degrees."* The video already carries 6% taper at 79
  degrees and begins as soon as the lid leaves its resting angle. There is no
  quiet stretch in it. `SLANT_ONSET_EASE=1` adds one, at the cost of departing
  from the footage.
* *"Visible height is h sin(theta)."* That is exactly `SLANT_EYE_LEVEL=1`. The
  video measures 0.37 — it crops 35% at 32 degrees where the rule takes 47%.

**And the caveat that outlives all of this:** the video is the app *plus a camera
4cm above the hinge*. The pinned mapping is exact only for the eye it assumes,
so reproducing the footage and looking right from the user's own chair are not
the same target. The user judged an earlier, correct-to-the-video build as
"falling backward" — that was this viewpoint gap, not a bug. Mac-Duo concedes
the same thing in its README. Photographs of the screen are biased too: a phone
is held further away than the eyes are, which makes the taper read as too
strong.

**The crop is `1 - sin(theta)` — the user's own rule, confirmed frame by frame.**
An earlier fit of `eyeLevel 0.37` came from eyeballing the picture's top edge in
five stills and was wrong. Measuring the panel's top edge against the picture's
fixed extent across 24 frames gives:

| panel splay | implied angle | `1 - sin(theta)` | measured crop |
|---|---|---|---|
| 1.162 | 66.2 deg | 8.5% | 10.3% |
| 1.212 | 59.5 deg | 13.8% | 14.5% |
| 1.243 | 55.5 deg | 17.6% | 18.3% |

Mean error 1.0% at `eyeDistance 2.9` (against 2.2% at 3.2 and 3.8% at 2.6). So
`eyeLevel 1`, `eyeDistance 2.9`.

**The soft grey rim was a red herring — it is the aluminium base reflecting in
the glossy screen**, not anything the app draws. The user identified it. The
measurement was real (**0.18 of the local wedge width** across every deep-fold frame and every
height sampled — widest at the top, gone at the hinge, growing with the bend.
across every deep-fold frame and height — which is exactly what a reflection of
a fixed object in a tipping mirror does) but the cause was not. The code is kept,
derived from the row's texture span rather than the blur radius, and defaults to
**off**: `SLANT_RIM`. Do not reintroduce it as a finding.

**Reading a dump.** The renderer pre-distorts: flat on screen the output looks
vertically stretched, and that is correct — the panel's foreshortening cancels
it. Judging a dump as if it were the final image is what rejected the right
answer once already.

### Still open on the look

Blur and dim were deliberately not retuned. The frames confirm the current
shape — strongest at the top, hinge staying clear — but the amounts were never
measured. They are environment variables, so they cost nothing to adjust.

## Workflow constraints — these dominate everything

**Every `make install` invalidates Screen Recording permission.** The app is
unsigned, so macOS keys the grant to the code hash. After each install the user
must go to System Settings > Privacy & Security > Screen & System Audio
Recording, **remove** the Slant entry and **re-add** it from /Applications.
Toggling off/on is not enough.

Consequences:
- **Batch changes.** Never install for one tweak.
- **Use the environment variables** (listed below) to tune without rebuilding.
- A real Developer ID certificate (99 USD/year Apple Developer Program) would end
  this. The user has not bought one.

**Stop the app:** `pkill -f SlantApp` or `make stop`. Always tell the user this
before launching anything. The overlay renders above the menu bar, so if it gets
stuck it hides the very menu needed to quit. This already forced the user to
restart their Mac once.

**Seeing the output without the user:** the killer tool.
```
open -a /Applications/Slant.app --env SLANT_DUMP=1 --env SLANT_DUMP_DIR=/tmp/x
```
Renders five fold stages to PNG through the exact live shader path, with the void
painted magenta so the visible region is unmistakable, then quits. Read those
PNGs directly. Capture can take 2-25s to start, so poll for the files rather than
sleeping a fixed time. **The terminal has no Screen Recording permission, so
`screencapture` does not work — this dump is the only way to see the output.**

**Xcode is not installed** (Command Line Tools only). Therefore:
- The Metal shader is compiled **at runtime** from `Fold.metal` shipped as a
  bundle resource. `Package.swift` uses `.copy`, not `.process`.
- **No XCTest and no swift-testing.** There is a hand-rolled harness in
  `Sources/TestKit` and tests are a plain executable: `make test`. 2004 checks
  currently pass, including a headless Metal render through the real shader. It has been verified to actually detect failures.

---

## Architecture — what works and is verified

| Module | Status |
|---|---|
| `LidSensor` | IOHID vendor 0x05AC / product 0x8104 / usage page 0x0020 / usage 0x008A. Probes report 7 (hundredths of a degree) then falls back to report 1 (whole degrees). 120Hz tracking / 10Hz idle. Device access confined to its own queue. Three-state hardware diagnosis. **Verified on device.** |
| `LidMotion` | Critically damped spring with velocity-dependent stiffness and adaptive sub-stepping; `LidStillness` learns the resting angle (4s dwell, 2 degree threshold, 55 degree floor); `FoldProgress` smoothstep with an 8 degree dead zone capped at a 75 degree ceiling, complete at 30 degrees. |
| `DesktopCapture` | ScreenCaptureKit, 10fps, BGRA, DisplayP3, self-excluded via a 1x1 on-screen "presence window", cached `SCContentFilter`, pauses frame delivery during a fold. |
| `FoldOverlay` | Borderless click-through NSWindow at `CGShieldingWindowLevel`, full `NSScreen.frame`, CAMetalLayer. |
| `FoldRenderer` | Metal. Heckbert square-to-quad homography; `MPSImageGaussianPyramid` sampled at a continuous mip level; blur and dim shaped by height and ramped on separate curves; opaque black void; corner vignette; Reduce Motion path; PNG dump diagnostics. |
| `FoldController` | Owns everything. Freezes the picture for the duration of a fold; display link capped at 60fps and paused at rest; sleep/wake with instant snap on wake; 25s overlay watchdog; demo mode that auto-quits after 3 cycles. |
| `MenuBar` | Status item: live lid-angle readout, health-state icon, Screen Recording deep link, "Quit and Reopen", Launch at Login, Quit. |
| `Lifecycle` | Sleep/wake/display-change observers with a bounded 5-attempt reconnect. |

**First-frame flash — fixed.** `hide()` only orders the overlay window out, so
the Metal layer kept the final frame of the previous fold and ordering it back in
flashed that frame for a refresh before the new one landed. The window now goes
on screen at zero alpha (`prepareHidden()`) and is revealed once two frames of
the current fold have been drawn — two rather than one because `render()` returns
at commit and presentation is asynchronous. Costs one refresh, about 16ms.

**Shipping artefacts written:** `README.md`, `LICENSE` (MIT), `NOTICE`
(Apache-2.0 attribution — a legal obligation, see below), `site/index.html`.

---

## Environment variables (tune without rebuilding)

```
SLANT_DUMP=1 SLANT_DUMP_DIR=/tmp/x   render 5 stages to PNG and quit
SLANT_DEMO=1                          drive from a timer, lid ignored; auto-quits
SLANT_PERIOD=9                        demo cycle seconds
SLANT_DEMO_CYCLES=3                   demo cycles before quitting

SLANT_EYE_DISTANCE=3.8                viewer distance; sets the side taper only
SLANT_EYE_LEVEL=1                     assumed eye as a fraction of the top edge
SLANT_REFERENCE_ANGLE=90              angle the picture is pinned at

SLANT_MODEL=pinned                    pinned (the video), flat (no magnification) or warp
SLANT_ONSET_EASE=0                    1 holds exact passthrough until the onset
SLANT_TAPER=0.30                      top draw-in, warp model only
SLANT_BLUR=90                         blur radius at full fold, source pixels
SLANT_DIM=0.5                         darkening at full fold
SLANT_BLUR_CURVE=0.5                  how late blur builds
SLANT_DIM_CURVE=0.7                   how early dim arrives
SLANT_BLUR_SPREAD=2.2                 blur shaping by height
SLANT_DIM_SPREAD=1.1                  dim shaping by height
SLANT_RIM=0                           soft side rim, as a share of the wedge
SLANT_HINGE_BLUR=0.02                 blur surviving at the hinge
SLANT_HINGE_DIM=0.10                  dim surviving at the hinge
SLANT_VIGNETTE=0.18                   corner falloff
SLANT_VOID=0                          brightness behind the panel

SLANT_DEADZONE=8                      degrees below resting before anything
SLANT_FULL_ANGLE=30                   angle at which the fold completes
SLANT_START_CEILING=88                blur/dim never start above this
SLANT_CAPTURE_FPS=10                  standby capture rate
SLANT_QUIET=1                          silence telemetry
```

---

## Research already done — do not redo

**Competitors** (cloned at
`/private/tmp/claude-501/-Users-hashtodi-Desktop-side-project-duo-animation/*/scratchpad/competitors/`;
re-clone if that scratchpad is gone):
Mac-Duo (sumimakito, Apache-2.0, 299 stars, the leader), hinge (noveum, MIT),
MacDuo (DhananjayBhosale, MIT), LidAngleSensor (samhenrigold, Apache-2.0, 4.2k),
macTilt (lqSky7), DuoFlip (AresNing), plus Bendy (paid, 4.99 USD, proprietary).

Web recreations of the real Duo animation: `chuspeeism/iphone-duo` (Three.js, MIT,
loads Apple's real USDZ) and `jal-co/iphone-duo`. **Neither contains Apple's
actual shader** — both are approximations, and jal-co's docs say so explicitly.

**Key findings:**
- The Duo illusion is **decoupled reprojection**: the panel gets real 3D
  perspective while the texture coordinate is computed from a *stationary* eye
  onto the flat unfolded plane. Shape foreshortens, picture does not.
- Blur and darkening use **separate schedules** from the geometry. Driving all
  three off one value is the most common reimplementation error.
- Edges should **fade to transparent**, not clamp. Clamping reads as smeared
  pixels.
- All Mac competitors use a **static height gradient scaled by progress**, not a
  travelling blur boundary.
- Dead zones in the field are 1-2 degrees (DuoFlip) or absolute ~90 degrees
  (Mac-Duo). Mac-Duo's default blur radius is 135.
- 5 of 7 competitors are menu-bar-only agent apps with no Dock icon.
- macTilt is the only one that tells users the permission needs a relaunch.
- DuoFlip auto-pauses during meeting apps.

---

## Known outstanding work

1. **Blur and dim amounts** — never measured against the reference; see above.
2. **Threshold hysteresis** — Mac-Duo guards the trigger edge with hysteresis and
   a velocity-predicted angle. We have a hard compare and may stutter at the
   boundary.
3. **Linear-light blur** — we blur gamma-encoded values; textures are
   `.bgra8Unorm` with no sRGB tag. Mac-Duo tags theirs `_srgb` end to end. Must be
   re-tuned together with the dim curve.
4. **Demo GIF does not exist.** `README.md` references `docs/demo.gif`. An
   embedded demo is the strongest predictor of GitHub stars. The user has Screen
   Studio. Record `SLANT_DEMO=1`.
5. **No settings UI** — environment variables only.
6. **Not signed or notarised** — needs the 99 USD Apple Developer Program.
7. **Spring direction lock**, meeting-app auto-pause, first-frame black-flash
   guard — all identified, none implemented.

## Licence obligation, not optional

`NOTICE` must ship. Slant uses Mac-Duo's Apache-2.0 homography approach,
mip-pyramid blur, shielding window level, presence-window technique and report-7
discovery, plus LidAngleSensor's HID identification. Both are Apache-2.0 and
require attribution. The file is already written — do not delete it.

## Specs and plans

- `docs/superpowers/specs/2026-09-11-slant-design.md`
- `docs/superpowers/plans/2026-09-11-slant.md` (16 tasks; 1-13 done, 14-16 partly)
