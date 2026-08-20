# Conduit — Audit & Redesign Strategy

> **Status: all five phases executed (2026-08-20).** What changed, and where this
> document was deliberately departed from, is recorded in §8 at the bottom.


*Written 2026-08-20 by a Fable 5 audit pass. This is the execution brief for a future
Opus session. Everything under "Verified" was checked against this machine's SDK and
running app — trust it. Everything else is judgment — argue with it if the code says
otherwise.*

**How to use this file:** work phases in order. Each phase has a Definition of Done and a
verification step. Do not start Phase 2 while Phase 1 DoD items are open. Re-measure idle
CPU after every UI phase — the perf invariants in §5 are the most fragile thing here.

---

## 1. Verdict

The engine is the strong half: measurement accuracy is proven to ~1% against `iostat`,
the benchmark's cache discipline is provably honest, USB link resolution is confirmed on
real hardware, and idle cost is 0.5%. **The product half is weak.** It looks like a
developer tool wearing cards, it has no icon, no settings, no eject button, no memory of
past results, and it never speaks up at the one moment users care — when a drive
connects on a degraded link. The redesign is not decoration; the current UI actively
undersells a genuinely rigorous engine.

---

## 2. Product audit — where it lacks

### P0 — absence of table stakes (app doesn't feel finished without these)

| Gap | Why it matters | Direction |
|---|---|---|
| **No app icon** | Empty `CFBundleIconFile`. Nothing says "unfinished" louder in the Dock. | Layered macOS-26-style squircle: gauge needle + USB glyph. Pipeline: PNG set → `iconutil` (verified present; `actool` also exists, surprisingly). |
| **No eject** | A drive list without eject is missing the #1 action people take on USB drives. Users will keep Finder open next to Conduit, which is a loss. | Eject button per device row + detail header, via `DADiskUnmount`/`DADiskEject` on the existing DiskArbitration session. Handle the busy-volume failure with the dissenter message. |
| **No Settings** | Apps that feel Apple have ⌘,. Nothing is configurable: launch at login, show-internal default, sample rate, menu-bar visibility. | Standard SwiftUI `Settings` scene. Launch at login via `SMAppService.mainApp` (verified in CLT SDK). "Show Dock icon" toggle via `NSApp.setActivationPolicy` for menu-bar-only mode. |
| **No benchmark history** | Results vanish on quit. The most valuable question a speed test answers is *"is this drive getting worse?"* — impossible without persistence. | Persist每 run keyed by drive serial (`Device Characteristics → Serial Number`, already read). JSON in Application Support is fine; no Core Data. Show last-run delta in results ("12% slower than 3 Jan"). |
| **Silent connect** | The moment a drive mounts on a bad link (USB 2.0 fallback, BOT, behind a hub) is exactly when the user is about to start a long copy. Conduit knows, and says nothing unless the window is open. | `UserNotifications` toast on connect: "SanDisk connected at 480 Mb/s — this drive supports 5 Gb/s. Try a different port/cable." This is the app's single biggest differentiator; nothing on macOS does it. |

### P1 — differentiators (what makes it worth existing vs. Blackmagic/AmorphousDiskMark)

- **Failing-hardware alerts.** Error/retry counters are already sampled but only
  displayed. Rising `Errors (Read/Write)` or `Retries` on a stable workload = failing
  cable, port, or flash. Alert once per session when the delta exceeds a threshold.
  Genuinely valuable and free — the data is already in hand.
- **Queue-depth metric.** The probe proved `Δ(Total Time)/Δ(wall)` = average queue depth
  (16.6s accumulated in a 1.0s window under load). Surface it as "Queue" in the detail
  grid — it's the number that explains *why* latency spiked. Never present it as a %.
- **Adaptive sampling.** 4 Hz always-on is a compromise. Idle → 1 Hz (even cheaper than
  today); active transfer detected → 8 Hz (SLC cliffs and sawtooths resolve better).
  The publish-gating already decouples UI rate, so this is sampler-only.
- **Benchmark realism.** Current test is QD1-only, 1 MiB blocks, max 4 GB:
  - Add a QD4–8 sequential pass (concurrent `pwrite` slices or `DispatchIO`). NVMe
    enclosures are underreported by 2–3× at QD1; the SanDisk numbers were fine but a
    10 Gb/s enclosure will look broken.
  - Add a 16 GB / "run until steady-state" option — 4 GB does not exhaust the SLC cache
    on modern TLC sticks, so the headline write number can still flatter.
  - Report min/avg/max per phase, not just avg — the 59–256 MB/s sawtooth we measured
    collapses misleadingly into "182".
- **Copy-in-progress card.** When sustained write activity is detected on a USB device,
  show a "transfer in progress — 182 MB/s, ~4 min at this rate for 40 GB" style card.
  Total size is unknowable from the block layer alone; show rate + elapsed + moved, not
  a fake ETA. Honest framing matters more than the ETA.

### P2 — later / conscious non-goals

- SMART health over USB needs SAT passthrough and a kext-free implementation is
  miserable — **non-goal** unless a library materializes.
- Notarized Developer ID distribution + Sparkle — only when it leaves this Mac.
- Localization (EN/AR incl. RTL) — only if it ships to an audience.
- Per-process I/O attribution ("Finder is doing this") — needs root or endpoint-security
  entitlements. Non-goal.

---

## 3. Engineering audit — debt and risks

1. **Zero tests.** The three most bug-prone pure functions are begging for XCTest-free
   unit coverage (a plain `swift test` target works under CLT):
   `USBLink.bitsPerSecond` (two-enum trap), the counter-delta/reset math in
   `ThroughputSampler.rate`, and `Volumes.isSystemPath`. These encode hard-won,
   empirically-derived rules — a refactor that breaks them will look correct.
2. **Swift 6 language mode is not enabled.** The concurrency patterns were designed for
   it (no `@unchecked Sendable` anywhere) but `Package.swift` doesn't set
   `.swiftLanguageMode(.v6)`, so nothing enforces it. Turn it on; fix what surfaces.
3. **`MonitorStore.apply()` has become the most intricate function in the app** — tick
   gating, dirty flags, structural-change fast-paths, three device buckets. It works,
   but its invariants live in comments. Extract the gating into a small, named,
   *testable* type (`PublishGate`) before the redesign touches this file, or the
   redesign will quietly break it.
4. **Manual `DeviceIdentity ==`** silently ignores new fields. Acceptable trade, but any
   new displayed field MUST be added to `==` or the UI won't update when it changes.
   This landmine is documented only in a comment; a test would enforce it.
5. **Random-write IOPS is slightly flattered** — `F_FULLFSYNC` fires after the loop, so
   the 577 IOPS on the SanDisk includes some drive-buffered writes. Either fold the
   flush time in or footnote the number in UI.
6. **Menu-bar label at 2 Hz** is fine, but the `MenuBarExtra` label closure still
   evaluates whenever *any* observed property it reads changes. Keep it reading only
   `menuBarText`/`usbDeviceCount` — nothing else, ever.
7. **`DiskWatcher` description-changed callback** fires on every mount *and* on volume
   renames etc. — currently harmless (it only invalidates topology) but don't attach
   heavier work to it.

---

## 4. Redesign strategy — "feels very Apple"

### 4.0 Platform decision (make it first)

Raise `platforms:` to **`.macOS(.v26)`** and adopt Liquid Glass. This is a personal-first
app on a Mac already running 26; dual-pathing `if #available` for 14 buys nothing.
**Verified:** `glassEffect`/`GlassEffectContainer` exist in the CLT SDK's SwiftUICore
interface; `ContentUnavailableView`, `Gauge`, `.inspector`, `symbolEffect`, TipKit all
present. The `@State` macro remains Xcode-only — the no-`@State` rule (§5) still stands.

### 4.1 Principles (the difference between "themed" and "Apple")

1. **Structure over chrome.** Apple apps get their feel from *standard containers* —
   source-list sidebar, unified toolbar, grouped forms, inspectors — not from custom
   cards. Delete the `card()` modifier as a goal, not a refactor casualty.
2. **One hero number per screen.** Apple screens (Battery, Storage, Screen Time) have a
   single focal metric and everything else recedes. Currently Read and Write shout at
   equal volume next to six equal stats. Pick the hero: **combined throughput now**,
   with read/write as the split beneath it.
3. **Color restraint.** The cyan/amber/green/red `Palette` is a dashboard, not macOS.
   Move to: system **blue** (read) and **orange** (write) — matching Activity Monitor's
   disk conventions — semantic `.secondary`/`.tertiary` for everything informational,
   and **red reserved exclusively for real problems** (errors, hub-capped link). Delete
   custom RGB values; use system colors so vibrancy/accessibility modes work free.
4. **Typography discipline.** System text styles only (`.largeTitle`→`.caption2`), the
   hero numeral in `.rounded` design + `.monospacedDigit()` — not full-monospace fonts
   for labels. Sentence case everywhere; kill the uppercase 10pt micro-labels except
   where Apple genuinely uses them (grouped-form section headers do it for you).
5. **Materials, not fills.** Panels sit on `.regularMaterial`/glass, not
   `.quaternary.opacity(0.35)`. On 26, the menu-bar panel is the flagship glass surface.
6. **Motion with meaning.** Keep `.contentTransition(.numericText())`. Add
   `symbolEffect(.pulse)` on the device icon while transferring, a spring insertion for
   newly connected drives, and nothing else. Respect Reduce Motion.
7. **Explain jargon in-place, not inline.** UASP/BOT/link-ceiling explanations move out
   of always-visible warning labels into ⓘ popovers and one TipKit tip each. Warnings
   stay visible only when actionable (capped link, BOT on a fast link).

### 4.2 Screen-by-screen

**Window chrome.** Keep `NavigationSplitView`, restyle sidebar as a proper source list:
section headers ("USB", "External", "Internal"), rows = icon + name + tiny live
sparkline on the right *only when active* (Wi-Fi-menu pattern). Toolbar: title = device
name, toolbar items = Eject, Speed Test (play.circle), Info toggle. **Kill the floating
segmented Live/Speed-test picker** — Live is the detail view; Speed Test becomes a
toolbar-launched **sheet flow** (see below).

**Device detail (Live).** Top: hero block — device glyph + name + capacity, then the
hero throughput numeral with read/write split beneath (small blue ▲ / orange ▼ pairs).
Below: the chart, full-width, axis-light, area-gradient fill (Fitness style), link
ceiling as today's dashed rule. Then a **grouped Form** (`.formStyle(.grouped)`) with
sections: *Connection* (negotiated link as a `Gauge`-style capacity bar, generation,
transport, hubs — with ⓘ popovers), *Activity* (IOPS, latency, queue depth), *Health*
(errors/retries — green checkmark row when zero, red rows when not), *Volumes* (rows
with free-space bars + per-volume eject). The grouped form is what makes it read
"System Settings," which is the most macOS-native pattern available.

**Speed test as a flow, not a tab.** Toolbar button → sheet: pick volume (defaults to
selected device's first volume), pick size, big prominent Start. During: the sheet shows
one large gauge (current MB/s), phase name, live curve building underneath, Cancel.
After: a **results summary card** — the four numbers in a clean grid, the write curve,
the honesty footnotes (flush delta, sawtooth/cliff annotation), a "compare to last run"
line from history, and a Share/Copy button that renders the card as an image. The
shareable card is the growth loop — every screenshot of it is an ad.

**Menu bar panel.** Model it on Control Center modules: glass background, one compact
module per USB device (name, link badge, sparkline, rate), footer row = Open Conduit ·
Settings ⚙ · Quit. Menu-bar *label* stays as-is (icon + fixed-width rate, 2 Hz).

**Empty state.** Replace the custom VStack with `ContentUnavailableView` (verified
present) — "No External Drives", `externaldrive.badge.questionmark`, one-line
description. Instant Apple.

**First run.** One dismissible sheet, three sentences: what the live meter measures
(block-layer I/O), what the speed test does (scratch file, cache-off, self-cleaning),
and the notification permission ask *with the reason shown first*.

### 4.3 App icon (no Xcode required — verified)

Squircle, dark-glass background, a speed-gauge arc in system blue with an orange needle,
subtle USB trident integrated into the needle's base. Produce 16→1024 PNGs, assemble
with `iconutil -c icns`; wire `CFBundleIconFile`. Generate the art via Higgsfield
image gen or hand-build in SVG→PNG; keep it geometric so it survives small sizes.

---

## 5. Invariants — DO NOT BREAK (hard-won, measured)

1. **No `@State`, `@Entry`, `@Animatable` anywhere.** CLT has no `SwiftUIMacros` plugin;
   the build fails. Use `@Observable` + the store, `@Bindable`, `@FocusState`,
   `@Environment`. (Memory: `swiftui-clt-no-state-macro`.)
2. **Idle CPU ≤ 1%, active ≤ ~6%.** Achieved via: (a) views never read raw `readings`;
   (b) all published collections are change-gated (`if x != new { x = new }`);
   (c) history publishes at 2 Hz via dirty-flag, samples at 4 Hz; (d) graph stops
   publishing after 60 s of zeroes; (e) menu-bar label reads only `menuBarText` +
   `usbDeviceCount`. Any redesign PR must re-run the `top -l 6` measurement.
3. **Benchmark phase order: write-with-`F_NOCACHE` before read.** `F_NOCACHE` does not
   evict resident pages — reordering silently reports RAM speed (measured 7× lie).
4. **`UsbLinkSpeed` first; never mix `USBSpeed` and `Device Speed` enum tables.**
5. **Delta map keyed on registry entry ID, never BSD name** (replug reuses `disk4` with
   zeroed counters). Negative delta ⇒ emit zero, rebase.
6. **Boot-volume refusal**: `/`, `/System/Volumes/*`, `/private/var/vm` — plus writable
   + headroom checks. Any new benchmark entry point re-uses the same guard.
7. **`kIOMainPortDefault`**, `CLOCK_MONOTONIC_RAW`, release every `io_object_t`.
8. **`DASessionSetDispatchQueue`**, never run-loop scheduling (dies during menu tracking).

---

## 6. Phased execution plan (for the Opus session)

### Phase 1 — Foundation & hygiene *(do first; everything else builds on it)*
- Bump platform to macOS 26; enable `.swiftLanguageMode(.v6)`; fix fallout.
- Extract `PublishGate` from `MonitorStore.apply()`; add a test target with unit tests
  for: link-speed mapping (incl. both enum tables), delta/reset math, `isSystemPath`,
  publish gating.
- **DoD:** `swift build` + `swift test` clean; idle CPU re-measured ≤ 1%.

### Phase 2 — Design system + window redesign
- New semantic color/typography layer replacing `Palette`/`Format` label styles (keep
  the number formatters — decimal-MB rule is correct).
- Sidebar-as-source-list, toolbar, grouped-Form detail, hero block, ContentUnavailableView,
  ⓘ popovers, TipKit for UASP/hub education.
- **DoD:** side-by-side screenshot review light+dark; idle CPU re-measured; no view
  reads ungated state (grep for `store.readings` returns nothing).

### Phase 3 — Speed-test flow + shareable results
- Sheet flow, gauge, results card with history comparison + share-as-image.
- Benchmark engine: min/avg/max per phase, QD>1 sequential pass, 16 GB option,
  fold flush into random-write IOPS or footnote it.
- Persistence: per-serial JSON history in Application Support.
- **DoD:** run on the SanDisk; verify scratch cleanup, history file written, second run
  shows delta line. Numbers within sanity of today's baseline (378/182).

### Phase 4 — Table stakes & proactivity
- App icon (`iconutil` pipeline). Eject everywhere. Settings scene (launch-at-login via
  `SMAppService`, dock-icon toggle, show-internal default, sample-rate).
- Connect-time notifications with link diagnosis; error/retry alerting; queue-depth stat.
- **DoD:** unplug/replug SanDisk → notification appears with correct link verdict;
  eject works with a file open (proper busy error); login-item toggles verified in
  System Settings.

### Phase 5 — Menu bar polish + adaptive sampling
- Control-Center-style glass panel; per-device modules; adaptive 1↔8 Hz sampler.
- **DoD:** menu-bar panel screenshot review; idle CPU with adaptive sampling ≤ 0.5%.

*Estimated shape: Phases 1–2 are one focused session; 3–5 one each.*

---

## 7. Open questions — resolved

1. ~~Personal tool forever, or eventual public release?~~ **Answered 2026-08-20: public,
   on GitHub, MIT, source-first.** That promotes notarisation from "not needed" to "the
   single biggest barrier to anyone testing it" — see §11. The shareable results card is
   now worth building; it stays unbuilt only for lack of time, not lack of reason.
2. Menu-bar-only default, or window app with menu-bar extra? **Window plus menu bar
   extra, with a "Menu bar only" setting.** Shipped.
3. App name: "Conduit" collides with several dev tools. Kept — the collisions are in
   other ecosystems and none are macOS storage utilities.


---

## 8. Execution record — 2026-08-20

All five phases landed. 49 tests in 10 suites, zero build warnings, Swift 6 language
mode with **no** `@unchecked Sendable` anywhere.

### Delivered

| Phase | Outcome |
|---|---|
| 1 Foundation | macOS 26 target, Swift 6 mode, `PublishGate` extracted, test target running |
| 2 Redesign | Semantic system colours, source-list sidebar, grouped-Form detail, hero metric, `ContentUnavailableView`, ⓘ popovers, speed test moved from tab to sheet |
| 3 Speed test | Per-drive history, QD4 read pass, 16 GB option, write range, run-over-run comparison |
| 4 Table stakes | App icon, eject, Settings scene with launch-at-login, connect-time notifications, error alerts |
| 5 Polish | Control-Center-style glass menu bar panel, adaptive 4 Hz ↔ 1 Hz sampling |

### Three bugs found by running it, not by reading it

1. **The engine only ran when a window was open.** `store.start()` hung off the main
   window's `.task`, so on any launch where macOS restored the window closed — the normal
   state for a menu bar app — the meter sat at zero forever. Latent since the first build.
   Now started from `App.init()`.
2. **`@MainActor` on `DiskWatcher` made its C callbacks main-actor-isolated**, so Swift 6
   emitted an executor assertion into them and the process took a SIGTRAP the instant
   DiskArbitration replayed the attached disks. The callbacks now live at file scope.
3. **The benchmark reported no progress and an empty graph** on any test short enough to
   finish inside one 100 ms reporting window.

### Departures from the plan, and why

- **Sampling is 4 Hz active, not 8 Hz.** 4 Hz is the rate whose accuracy was verified
  against `iostat` and `dd` to about 1%. The detail 8 Hz would add is already captured by
  the benchmark's own 10 Hz curve, so doubling the cost of the most expensive state would
  buy a duplicate.
- **TipKit was not adopted.** The ⓘ popovers cover the same teaching need without adding
  an onboarding framework and its state machine.
- **Share-as-image was not built.** It only earns its place if the app ships to an
  audience, which is still open question 1 below.
- **`.equatable()` was needed on the detail view, sidebar row and chart.** Not in the
  original plan. `history` is one dictionary shared by every device, so the internal SSD's
  constant background I/O invalidated the chart of a completely idle USB drive twice a
  second. History is now also scoped to drives that are actually on screen.

### Measured after the redesign

- Idle, once the graph window clears: **0.4% CPU, 69 MB**.
- Device selected with the live chart drawing: **~5%**.
- Sampler itself: 0.5 ms per 250 ms tick.
- SanDisk 3.2Gen1, 512 MB: 382 MB/s read, 381 MB/s at QD4, 187 MB/s write, flush verified,
  scratch file removed. Consistent with the pre-redesign baseline of 378/182.

### Still open

- The exFAT `F_FULLFSYNC` fallback has never executed (the test drive is HFS+).
- The hub-capped-link warning has never fired (the test drive is plugged in directly).
- The three questions in §7 are unanswered; sensible defaults were chosen for each
  (personal tool, window-plus-menu-bar with a menu-bar-only setting, name kept).


---

## 9. Adversarial review round — 2026-08-20

A six-lens review with adversarial verification raised 34 findings, 26 of which survived.
Everything below was fixed and covered by a regression test where a test was possible.
Test count went 49 → 59.

### Safety

- **`/Volumes/Recovery` was offered as a benchmark target.** It is writable, sits on the
  boot disk, and is not under `/System/Volumes/`, so every guard missed it — a 16 GB
  scratch file would have landed on the Recovery volume. Now excluded via
  `MNT_DONTBROWSE`, the same flag Finder uses to decide what to hide. A path blacklist
  would have meant guessing every name Apple might use.
- **The free-space guard trusted a stale snapshot** taken when the volume was picked.
  It now re-reads the filesystem at run time.
- **Headroom was a flat 512 MB** — a 200% cushion on a 256 MB test and 3% on a 16 GB one.
  Now `max(512 MB, 10% of the test)` on top of the test itself.
- **Eject had no boot-disk check** and would happily eject a drive mid-benchmark.
- **A force-quit stranded the scratch file** until the next test on that volume. Swept at
  launch across every writable non-system volume.
- **`try?` swallowed real I/O errors** in the QD4 and random passes, so EIO from a dying
  drive rendered as a blank cell on an otherwise successful report.

### Wrong numbers

- **The toolbar Speed Test button could benchmark a different drive** than the one
  selected, because the target was only defaulted when unset.
- **A cancelled run was recorded as a completed one** and became the comparison baseline.
- **The running gauge paired an auto-scaling number with a hardcoded "MB/s"**, so a
  gigabyte-per-second reading was labelled megabytes.
- **Test sizes were binary but labelled decimal** — "1 GB" moved 1.07 GB, against the
  decimal rule the project documents everywhere else.
- **"Compared to last time" compared runs of different sizes**, reporting a size change as
  a speed change.
- **`lineRateLabel` used integer division**, rendering a 1.5 Mb/s low-speed link "1 Mb/s".
- **The UASP flag was ignored above 10 Gb/s**, crediting a bulk-only 20 Gb/s enclosure
  with a UASP ceiling.

### Performance

- **The menu bar panel's `glassEffect` ran continuously while the panel was closed.**
  `MenuBarExtra(.window)` keeps its content alive, and a profile showed
  `vSepConvolveARGB8bgf_vec` — the blur convolution — as the largest real-work leaf in
  the whole process. Idle sat at ~10%; removing the glass, together with the adaptive
  sampling fix below, took it to **~1.7%**. macOS already gives a menu bar window its own
  vibrant material, so the glass was redundant as well as expensive.
  *(Corrected: an earlier version of this note also claimed the per-device `Chart` was
  removed. That edit silently failed to apply, and round two measured the chart at 0.13%
  against 0.16% without it — noise. The chart stays; the win was the blur and the
  sampling rate.)*
- **Adaptive sampling never engaged.** Quietness was measured across all drives, and the
  internal SSD's background chatter reset the counter on nearly every tick. It now
  ignores internal drives.

### Correctness

- **The volume picker tagged options by the whole `VolumeRef`**, which contains
  `freeBytes` — so the visible selection silently cleared itself whenever free space
  changed. Tagged by mount path now.
- **`stop()` was a one-way door**: cancelling the pump task ended the sampler's
  `AsyncStream` permanently, so a later `start()` returned a store that never received
  another reading.
- **The notification authorization request raced**: a second drive arriving during the
  first request was silently dropped. Callers now await the same request.
- **The error alert fired on any nonzero lifetime counter** with absolutist copy. It now
  requires a real error or retries past a noise floor, and says "worth checking".
- **Two contradictory notes** were rendered together when `F_FULLFSYNC` was refused.
- Dead `Tab` enum and `selectedTab` removed.

### Claims that did not survive

- "`glassEffect` costs 62% CPU" — the direction was right and the fix was real, but the
  figure was not reproducible; measured idle was ~10% before the fix, not 62%.
- "Idle is ~6%, six times the invariant" — measured within the graph's 60-second scroll
  window rather than after it. The honest figures are ~1.7% with a drive doing light
  background I/O and 0.4% when the machine is genuinely quiet.

### Deliberately not done

- Share-as-image on the results card, and per-row eject in the sidebar. Both are real
  gaps against §4.2; both wait on open question 1 (does this ship to anyone?).
- A first-run explanation before the notification prompt. The prompt is already deferred
  until there is something worth saying, which carries most of the context.


---

## 10. Second review round — 2026-08-20

The first round's synthesis agent died on a session limit; resuming it produced a ranked
verdict and three defects the first pass had missed. All fixed. Tests 56 → 60.

**Verdict returned:** *"Ship it… Nothing crashes, nothing loses data, nothing lies about
throughput."*

### Must-fix, all confirmed on the machine

- **The default test size matched none of the picker's options.** The store defaulted to
  `1 << 30` while the picker offered `1_000_000_000`, so the segmented control opened with
  nothing selected and the first run recorded an unlabelled 1.07 GB — which then failed
  the same-size guard and silently orphaned its own comparison baseline. The second time
  the binary/decimal split bit this file, so sizes now have exactly one definition
  (`BenchmarkSize`) that both the picker and the default read from.
- **The "Open at login" switch registered and then unregistered itself.** It was an
  `@StateObject` plus `.onChange`, which cannot distinguish a user's tap from the code's
  own write: seeding the switch on appear fired the handler, and the handler's snap-back
  re-entered it. A single tap produced `[register(), unregister()]`, the switch flipped
  itself off, and the error text was cleared before it could be read. Now an explicit
  `Binding` whose setter is the only thing that can act.
- **"Menu bar only" never applied on launch.** `applyActivationPolicy()` ran from
  `App.init()`, where `NSApp` is nil, and `NSApp?.` swallowed it — so the preference only
  worked in the session it was toggled in. Now `NSApplication.shared` (which cannot fail
  quietly) on the next run-loop turn. Verified end to end: `menuBarOnly = true` →
  `background only = true` at launch.

### Also fixed

- The sidebar's bottom divider was painted **through** the toggle: two sibling views in a
  `safeAreaInset` builder form a `TupleView`, which overlays rather than stacks.
- `DiskWatcher.stop()` dropped the last reference to its callback box with no barrier
  against a callback already running on the DA queue — a use-after-free reproducible under
  ASan. Unscheduling a session is not a barrier; it now drains the queue first.
- A 12 Mb/s full-speed device (a microcontroller in bootloader mode) was told it was
  "running at USB 2.0 speed" and advised to change its cable. Sub-high-speed links now get
  no advice, because being full-speed is a design, not a fault.

### Explicitly parked

The review named four items as confirmed-but-not-worth-fixing, and they are recorded here
so they are not raised a third time: the "link ceiling" rule label vs "wire ceiling" copy,
the dead `capacityBar` view extension, the per-device chart in the menu panel, and the
missing first-run sheet before the notification prompt.
