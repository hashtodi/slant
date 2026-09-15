# Slant — Design Spec

**Date:** 2026-09-11
**Status:** Approved for implementation

## 1. Overview

Slant is a macOS menu bar app that bends, blurs and dims the live desktop in real time as
the user closes their MacBook lid, driven by the built-in lid-angle sensor. Closing the lid
makes the desktop lean away in 3D and soften, as though the screen itself were a physical
surface tilting out of view.

It is a deliberate, single-purpose novelty utility. It does one thing well and has no
configuration beyond on/off.

### Context

Apple announced the foldable iPhone Duo on 2026-09-09. Its open/close animation went viral
and triggered a wave of macOS clones within 48 hours. Six exist at time of writing:

| Project | Stars | License | Notes |
|---|---|---|---|
| sumimakito/Mac-Duo | 299 | Apache-2.0 | Leader. Best render pipeline and sensor resolution. |
| DhananjayBhosale/MacDuo | 77 | MIT | Best permission handling. Five effect modes. |
| noveum/hinge | 49 | MIT | Best copy and lifecycle. No demo media. Not notarized. |
| lqSky7/macTilt | 24 | none | Dense technical README, no inline demo. |
| AresNing/DuoFlip | 10 | none | Most rigorous docs, hype-free. |
| CakeAL/mac-duo | 2 | MIT | Chinese-only, ASCII art only. |
| trybendy.app (Bendy) | n/a | proprietary | $4.99. Three named styles. |

Slant is the seventh entrant. It does not win on features; it wins on motion quality,
honest failure messaging, and presentation. See section 9.

## 2. Goals

- Sub-degree smooth motion, smoother than any existing implementation.
- Correct behaviour on sleep, wake, display changes and termination.
- Negligible idle cost; no measurable battery impact when the lid is not moving.
- A failure message that tells the user *why* when the hardware is unsupported.
- A README and landing page built on the evidence in section 10.

## 3. Non-goals

- No support for Macs without a lid-angle sensor. Explicitly out of scope (decided
  2026-09-11: "let's do things that don't scale, start with sensor only").
- No external display support. The effect applies to the built-in display only.
- No preferences window, no sliders, no effect styles in v1.
- No Mac App Store distribution. Structurally impossible; see section 4.
- No web version in v1.

## 4. Hard constraints

**Unsandboxed.** App Sandbox blocks arbitrary `IOHIDManager` vendor/product matching. All
six competitors ship unsandboxed and cannot do otherwise. Consequence: Developer ID +
notarization, distributed as a DMG. App Store is permanently off the table.

**Screen Recording permission required.** ScreenCaptureKit needs it. This is the single
biggest adoption friction and must be addressed head-on in the UI, README and landing page.

**Hardware gated.** Lid-angle sensor introduced with the 2019 16-inch MacBook Pro. Absent on
M1/M2 machines including every M1 Air and M1/M2 13-inch Pro. Target dev machine is
`Mac16,8` (M4 Pro), which is supported.

**Platform:** macOS 14+, Apple Silicon.

## 5. Architecture

Swift Package Manager. `make build` produces a `.app` bundle. No checked-in `.xcodeproj`.
`LSUIElement = true` (agent app, no Dock icon).

```
Sources/
  SlantApp/         AppDelegate, wiring, LSUIElement entry point
  LidSensor/        IOHID access, report probing, hardware diagnosis
  LidMotion/        critically-damped spring, velocity, settle detection, calibration
  DesktopCapture/   SCStream setup, presence window, permission verification
  FoldOverlay/      borderless click-through NSWindow at shielding level
  FoldRenderer/     Metal: homography + mip-pyramid blur + linear-light dim
  MenuBar/          status item: toggle, launch at login, quit
  Lifecycle/        sleep/wake, screen-parameter changes
Tests/
  LidSensorTests/   report-byte parsing
  LidMotionTests/   spring math, calibration, angle to progress
  FoldRendererTests/ homography math
```

Each module has one purpose and a narrow interface. The four pure-logic modules are unit
tested; capture, overlay and render are verified by running on hardware.

### 5.1 LidSensor

Matches `IOHIDDevice` on vendor `0x05AC`, product `0x8104`, usage page `0x0020` (Sensor),
usage `0x008A` (Orientation) via `IOHIDManagerSetDeviceMatching`.

**Report probing, in order:**

1. **Report ID 7** — 5 bytes `[0x07, b0, b1, b2, b3]`, little-endian 32-bit,
   **hundredths of a degree**. Probe this first. Source: Mac-Duo.
2. **Report ID 1** — 3 bytes `[0x01, lo, hi]`, little-endian 16-bit, **whole degrees**,
   range 0...360. Fallback only.

Both read via `IOHIDDeviceGetReport` with `kIOHIDReportTypeFeature`.

Report 7 is the single most important technical decision in this spec. Every competitor
except Mac-Duo hardcodes report 1 and then fights whole-degree stepping downstream with
smoothing. Reading hundredths of a degree eliminates the problem at the source.

**Hardware diagnosis, three states.** Modelled on LidAngleSensor's two-tier probe:

- `.supported` — device matched and a report was answered.
- `.presentButUnreadable` — product `0x8104` exists under a different usage page
  (typically vendor page `0xFF00`). The hardware is there but not exposed readably.
- `.unsupported` — no matching device. Cross-checked against a static `sysctlbyname("hw.model")`
  table so we can name the machine.

Each state maps to a distinct, specific user-facing message. No competitor does this.

**Polling.** 120Hz (8.33ms) while tracking, 10Hz (100ms) idle, via `DispatchSourceTimer`.
Source: hinge.

### 5.2 LidMotion

A critically-damped spring integrated with semi-implicit Euler, driven every frame by
`CADisplayLink`, decoupling the sensor cadence from the render rate. Base frequency 16.

Rejects single-sample sensor noise with a per-sample delta clamp. Tracks velocity with
exponential smoothing for settle detection; when the spring settles, the display link is
paused.

**Auto-calibration.** No user-facing threshold. A hysteresis dwell detector (anchor moves
only on a >= 2 degree change, requires 1-5s of stillness) learns the angle at which this
user habitually rests the lid. Seeded at 100 degrees. Source: MacDuo's `LidStillness`.

**Fold progress.** `progress = clamp((openAngle - angle) / (openAngle - closedAngle), 0, 1)`
where `closedAngle = 5`. Progress 0 means no effect; 1 means fully folded.

### 5.3 DesktopCapture

`SCContentFilter(display:excludingApplications:exceptingWindows:)` scoped to the built-in
display (`CGDisplayIsBuiltin`). Configuration: `kCVPixelFormatType_32BGRA`, Display P3,
`showsCursor = false`, `queueDepth = 5`. Frames wrapped zero-copy via `CVMetalTextureCache`.

**Presence window.** A permanent 1x1 pixel window at `alphaValue = 0.004` is kept alive at
all times so the app is enumerable in `SCShareableContent.applications` before the real
overlay exists. ScreenCaptureKit only lists applications that own a window; without this,
the first capture filter built after launch cannot find our own app to exclude, and we
capture our own output. Source: Mac-Duo.

**Permission verification.** Do **not** trust `CGPreflightScreenCaptureAccess()` — it can
retain a stale result. Verify with a real `SCShareableContent` fetch. On denial, inspect
`SCStreamErrorDomain` for `.userDeclined` and surface a precise message with the exact
Settings path. Source: MacDuo.

### 5.4 FoldOverlay

Borderless `NSWindow` subclass, `canBecomeKey` and `canBecomeMain` both `false`.
`isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`,
`ignoresMouseEvents = true`. `collectionBehavior`: `.canJoinAllSpaces`, `.stationary`,
`.ignoresCycle`, `.fullScreenAuxiliary`.

Window level `CGShieldingWindowLevel()` — above menu bar, notch, Dock and full-screen apps.
Source: Mac-Duo. Sized to `NSScreen.frame` (full framebuffer, which already includes the
notch region), not `visibleFrame`.

### 5.5 FoldRenderer

A 3x3 projective homography (Heckbert square-to-quad) computed from four 3D-projected
corners, with a genuine hinge rotation: `scale = depth / (depth + y * sin(separation))`.
The fragment shader inverse-maps each output pixel into picture space.

Blur is free: sample a `MPSImageGaussianPyramid` at a continuously computed mip level
rather than running a separate blur pass.

```metal
float mipLevel = clamp(log2(max(blur * maxRadius, 1.0)), 0.0, maxLevel);
float4 colour = picture.sample(linearSampler, texCoord, level(mipLevel));
colour.rgb *= pow(1.0 - maxDim * fade, 2.2);   // dim in linear light
```

Source: Mac-Duo. This is materially cheaper than hinge's 4-texture cross-fade and produces
real perspective rather than a UV squeeze.

**Frame rate.** Capped to `min(screen.maximumFramesPerSecond, 60)` even on ProMotion, and
the display link is paused whenever the spring is at rest. This fixes the one battery flaw
in Mac-Duo, whose display link is uncapped and will drive 120Hz on ProMotion panels.
Source: hinge.

### 5.6 MenuBar

One status item. Menu: **Slant On/Off** toggle, **Launch at Login**, **Quit**. Nothing else.

Launch at login via `SMAppService.mainApp.register()`, handling `.requiresApproval` and
deep-linking to `SMAppService.openSystemSettingsLoginItems()`. Source: hinge.

### 5.7 Lifecycle

- `NSWorkspace.willSleepNotification` / `didWakeNotification` and
  `screensDidSleepNotification` / `screensDidWakeNotification`: tear down capture and
  overlay, then resume.
- On wake, reconnect the HID device with 5 retries at 1s backoff — the device is briefly
  absent post-wake. Source: hinge.
- `NSApplication.didChangeScreenParametersNotification`: re-resolve the built-in screen.
  Diff `displayID` and `frame` to ignore false triggers from brightness changes.
  Source: Mac-Duo.
- `applicationWillTerminate`: close the `IOHIDDevice` and stop the stream cleanly.

## 6. Degradation and error states

| Condition | Behaviour |
|---|---|
| `.supported` | Normal operation. |
| `.presentButUnreadable` | Named message: sensor present but exposed on the vendor page. Quit cleanly. |
| `.unsupported` | Named message including the detected `hw.model`. Quit cleanly. |
| Screen Recording denied | Precise message with the exact Settings path, plus the stale-entry hint. |
| External display only | No effect. Not an error. |
| Sleep | Full teardown, resume on wake. |

## 7. Testing strategy

**Unit tested (pure logic):**
- Report-byte parsing: both report 7 and report 1 layouts, endianness, range clamping,
  malformed and short buffers.
- Spring math: convergence, no overshoot, settle detection.
- Calibration: dwell detection, anchor movement thresholds, seeding.
- Angle to progress mapping: boundaries, clamping.
- Homography: square-to-quad correctness against known point sets.

**Hardware verified (run on `Mac16,8`):**
- Capture starts and excludes our own overlay.
- Overlay sits above menu bar, notch, Dock, full-screen apps.
- Effect tracks a real lid close smoothly.
- Sleep/wake cycle recovers.
- Idle CPU at rest is negligible.

TDD applies to every unit-testable component: test first, watch it fail, then implement.

## 8. License obligations

Slant ships **MIT**.

Because the homography approach and the `MPSImageGaussianPyramid` mip-blur technique come
from Mac-Duo (Apache-2.0), we must ship a `NOTICE` file reproducing Mac-Duo's notice
("Mac Duo, Copyright 2026 Makito. Originally developed by Makito."), include a copy of the
Apache-2.0 license text, and state that any directly copied files were changed.

The HID constants and report layouts originate in Sam Henri Gold's LidAngleSensor
(Apache-2.0). The bare facts (`0x05AC`, `0x8104`, `0x0020`, `0x008A`, report layouts) are
not independently copyrightable, but we credit the work inline regardless — MacDuo already
models this well.

An explicit "not affiliated with Apple" disclaimer ships in the README. Every surviving
competitor carries one.

## 9. Differentiators

Not features. Three things, each evidence-backed:

1. **Sub-degree motion.** Report 7 plus a critically-damped spring plus a 60fps cap.
   Smoothest and lightest of the set.
2. **Honest failure.** Three diagnosed hardware states with specific messages, where every
   competitor prints a dead end.
3. **Presentation.** An embedded demo above all prose in the README — the strongest
   observed predictor of stars, and precisely what the best-written competitor lacks.

## 10. Presentation requirements

Derived from teardowns of all six READMEs and four landing pages.

**README order.** Tagline, then **embedded GIF before any prose** (non-negotiable; every
repo with inline motion outperforms every repo without it), then 3-5 bullets, install,
permission callout with the privacy line, honest compatibility including exclusions, build
from source, Apple disclaimer, license. Hero as GIF with an MP4 link below for full quality.

**Landing page.** Hinge's register: roughly 200 words, about 10 short blocks, one and a half
screens, two-step type scale (one oversized hero line, one small body size, no intermediate
ladder), zero color accents, light theme, sentence fragments, physical adjectives never
superlatives, one CTA repeated, no social proof.

Two deviations from Hinge, both evidence-backed:
- An interactive draggable lid slider above the fold (from BendMac) so a visitor feels the
  effect without installing.
- The hardware requirement stated **in the hero**, not in footer fine print. All four
  landing pages bury it; a visitor on an M1 Air downloads, fails and churns. This is the
  single biggest conversion mistake in the category and it is free to fix.

**Wordmark.** `SLANT` with the L tilted. The L already reads as a hinge.

Naming note: "Tilt" was rejected — lqSky7's project already ships as macTilt.

## 11. Build and distribution

`make build` produces `Slant.app`. Signed with Developer ID, notarized, stapled, shipped as
a DMG. Apple Developer Program membership is 99 USD/year and is the only hard cash cost;
it buys past the Gatekeeper warning that hinge currently subjects its users to.
