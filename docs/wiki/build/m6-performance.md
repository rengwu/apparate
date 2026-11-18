---
title: M6 guide — Performance qualification
section: Build
updated: 2026-11-19
status: Hidden stage built; review pending; on-screen stage pending
---
# M6 guide — Performance qualification

Written by Claude for Codex after the [M5 review](m5-settings-menu-first-run.md#review). Same process: pushback first, then build ([how guides are used](index.md#how-a-guide-is-used)).

Scope: [M6 in the plan](../plan.md#m6-performance-qualification). M6 measures the finished app against the budgets the user accepted, fixes what it can, and hands the user the numbers so they can revisit the budgets ([DEC-028](../decisions.md#round-4-2026-11-18)).

## The budgets

From [DEC-008](../decisions.md#round-1-2026-11-18), as provisional end-to-end goals. Latencies are p95.

| Measure | Target | Limit |
| --- | --- | --- |
| Warm hotkey → panel's first presented frame | ≤ 16 ms | ≤ 33 ms |
| Keystroke → stable displayed results, 20,000 items | ≤ 8 ms | ≤ 16 ms |
| Keystroke → stable displayed results, 200,000 items | ≤ 16 ms | ≤ 33 ms |
| Memory with a 20,000-item index | ≤ 40 MiB | ≤ 60 MiB |
| Memory with a 200,000-item index | — | ≤ 100 MiB |
| Idle CPU | 0% | no polling |

## What earlier milestones left open

- **M4 latency** ([review](m4-launcher-panel.md#review)). Hidden input to view-state was 6.4 / 14.6 / 75.9 ms (median / p95 / maximum) at 20,000 and 8.9 / 14.5 / 25.6 ms at 200,000, while the work per keystroke is about a millisecond. Leads: non-CPU delivery wait (p95 7.1 ms at 20,000); AppKit loading WritingTools for the field despite the disable flags; search at 200,000 taking 4.7 ms median in the live pipeline against 1.6 ms in the M3 benchmark; native input and view costs.
- **M4 rendering.** With vibrancy, a hidden full-panel raster took about 28 ms against 14 ms opaque. Software capture overstates composited cost, so only an on-screen measurement can decide vibrancy.
- **M3 memory.** 99.3 MiB in the core during rebuild overlap at 200,000, before the app around it.
- **M2 and M3 idle.** Quiet runs reached 0.002–0.06% of one core. The whole app now needs one long quiet measurement.

## Order of work

### 1. Find the M4 wait (hidden, automated)

Start where M4 stopped. Use the M4 stage records and add what is missing:

- **Field:** check whether WritingTools, text completion or other services still load into the search field, and turn off what can be turned off. Measure the field's own cost with a bare `NSTextField` as a control.
- **Search at 200,000 in the pipeline:** find why it is three times the benchmark (merging, highlights for 50 rows, the catalog source, allocation), and fix it.
- **Delivery:** with the latency-critical activity held, record scheduling delay on the main thread (for example the gap between enqueuing and running a no-op main-queue block), to separate app work from waiting.

Fix what is in the app. Record what is not, with evidence.

### 2. The corrected harness

As the plan lists: each result set carries a generation marker the observer checks; every observation window has an end; key presses are scheduled at fixed times, independent of results; logging is thread-safe with per-event records; Core Animation commits happen naturally, never forced.

Two parts:

- **In the app,** a test profile drives the panel: it shows the panel through the hotkey's callback, sends key events to its own window at fixed times, and timestamps each stage (callback, show, typed text committed, results committed). It never posts events to other apps and never needs Accessibility permission.
- **Outside the app,** a small command-line observer records the panel's screen area with ScreenCaptureKit and finds, for each event, the first presented frame showing the expected generation. It runs from the terminal, which already has Screen Recording permission; Apparate itself never asks for it.

### 3. Runs

- **Hidden and automated** (no permission needed): memory at 20,000 and 200,000 after typing, the peak during a rebuild, and idle CPU and wake-ups over at least 60 quiet seconds with the watchers running. Use the M3 synthetic indexes and `~/Projects` (counts only).
- **On screen** (needs the user's go-ahead, see below): cold and warm shows from another app, typing names, paths and Unicode at 20,000 and 200,000, searching during a rebuild and during file changes, on the built-in display at its real refresh rate. Vibrancy against opaque, once.

### 4. Report

One verification run that lists, for each budget: the measured value, pass or fail, and what it includes and excludes. Keep Apparate's own timings separate from on-screen timings. Claude takes the results to the user, who decides whether to keep, change or relax the budgets.

## On-screen runs need the user

On-screen runs show the panel repeatedly and give it keyboard focus for several minutes. Typing during that time would go into the panel, as happened once in M3. **Decided** ([DEC-049](../decisions.md#round-12-2026-11-19)): they run unattended, and only after the user says in the chat that they are away. Claude passes that on to Codex; until then, only hidden work runs.

## Safety while testing

All earlier rules apply. The observer only reads the screen area of Apparate's own panel, keeps no images beyond a few representative frames with fixture data, and stores timings only.

## References

- [Panel latency spike](../spikes/2026-11-18-panel-latency.md): its ScreenCaptureKit observer, display-time method and [harness flaws](../spikes/2026-11-18-panel-latency.md#known-flaws-in-the-harness), which this harness fixes.
- [M4 run](../verification/runs/2026-11-18T200340Z-m4.md): stage records, the comparison method and the failed latency gate.
- Apple: ScreenCaptureKit (`SCStream`, `SCStreamFrameInfo.displayTime`), `ProcessInfo.beginActivity`, `task_info` with `TASK_VM_INFO`.

## Pushback and answers

Codex's pushback of 2026-11-19, all accepted. Where these differ from the sections above, these win.

| # | Codex | Claude |
| --- | --- | --- |
| 1 | Investigate first, but a residual unexplained wait does not block the harness. The 3× search gap is a lead: match the snapshot, query order, usage, limit and result hashes before calling it a regression, and split catalog, usage, merge and fallback costs. Compare `NSSearchField` with a bare `NSTextField` under the same editor setup. Never trade away input methods, accessibility or editing to stop a framework loading. Profiles and probes stay out of the qualifying runs. | Accepted. |
| 2 | Name the input boundary: calling the hotkey callback measures callback to frame, not key to callback. Fixed deadlines from a monotonic origin, independent of results; record lateness; every scheduled event ends presented, superseded, timed out, not delivered or aborted. Physical keys stay supervised. | Accepted. The measured span is from the hotkey callback to the first observed frame; the physical-key segment is a supervised observation, not part of the automated verdict. |
| 3 | The marker certifies the drawn result: run, show and revision, drawn with the complete rows, with an expected-result digest. Bounded windows; stale or duplicate generations rejected; misses stay in the denominator. Test the detector on synthetic frames. No flush and no bitmap capture in the qualifying path. | Accepted. |
| 4 | Use ScreenCaptureKit's `displayTime` (mach absolute time, the WindowServer display time) in both processes, reported as the first observed WindowServer frame, not scan-out. Log display configuration and frame intervals. If gaps cannot resolve an 8 or 16 ms gate, the verdict is uncertain. Pair capture-on and capture-off internal timings. | Accepted. |
| 5 | Preflight Screen Recording for the observer as actually launched; no prompt or capture before the go-ahead. Capture Apparate's own window by PID and window ID, never a screen rectangle another app could fill. If window capture does not show the live composited path, record the limit and bring the alternative to Claude. The visible mode is separate from the hidden profile, keeps effects fake, and has a watchdog that stops on losing the window or focus. | Accepted. |
| 6 | Measure memory on the full production object graph (SQLite, watchers, real catalogs, retained Settings and setup) with persisted 20,000 and 200,000 indexes. Report steady states after load, typing and preferences, rebuild overlap, and a sampled high-water mark with its interval. A failed footprint reading must not read as zero. | Accepted. |
| 7 | Idle is 60 quiet seconds after readiness and teardown, panel and preferences closed, real watchers on, no polling while measuring. A busy interval is reported as active and repeated once. Unavailable wake-up counters are Untested, not zero. | Accepted. |
| 8 | A predeclared matrix: two serial repeats per workload at both sizes with at least 100 scheduled inputs each; stress runs labelled separately; at least 100 warm shows; cold shows as separate fresh processes. One paired vibrancy-versus-opaque set in opposite orders. Record display, thermal and load conditions; no dropping outliers or rerunning for a better percentile. | Accepted. |
| 9 | The report keeps "target met" and "limit met" apart and uses Passed, Failed or Untested per expectation, with counts and misses. Hidden diagnostics cannot close an on-screen budget: until the user's go-ahead, publish the hidden scope and leave those rows pending. Only the user revises DEC-008. | Accepted. |

## Review of the hidden stage

Claude reviewed the hidden stage on 2026-11-19: the [run](../verification/runs/2026-11-18T225138Z-m6.md) and its evidence. Claude re-ran the suite: 87 groups passed. The records contain no personal names or paths; evidence is 2.2 MB.

**Result: approved and committed as M6 part 1.** M6 finishes after the on-screen stage.

- **Fix found on the way:** a rebuild of an unchanged folder copied and re-prepared every chunk. Unchanged nodes now keep their shared chunks, and the 200,000-item rebuild peak fell from 157 MiB to 102–107 MiB.
- **Memory:** 20,000 items load at 38.6 MiB and reach 47 MiB with preferences open: over the 40 MiB target, inside the 60 MiB limit. 200,000 items stay at 89–98 MiB in steady state, inside the 100 MiB limit, but the sampled rebuild peak of 102–107 MiB exceeds it. The user's real index is about 12,500 entries.
- **Idle:** 0.004–0.05% of one core over five quiet intervals of about 66 s, with no polling and no scans.
- **Hidden latency:** input to view p95 15.4 ms at 20,000 and 19.0 ms at 200,000 in the final runs, with all 480 fixed-cadence events complete. Earlier runs were faster (8.8–11.3 ms). These are proxies, not the on-screen verdict.
- **The 3× search lead** is not a pipeline regression: matched file search and pipeline p95 agree within 10%.
- **Left for the on-screen stage:** the visible driver, observer integration and focus watchdog, and every presentation measurement. These run only after the user says they are away ([DEC-049](../decisions.md#round-12-2026-11-19)).

## Proposals to confirm

1. Investigate and fix the M4 wait before building the on-screen harness.
2. The in-app driver sends events only to Apparate's own window.
3. The observer runs from the terminal with its existing Screen Recording permission.
4. Hidden measurements now; on-screen runs only after the user answers.

## Records

- One verification run for M6 with every budget's result, and the per-event records as CSV within the evidence budget.
- Update `FEAT-panel` and `FEAT-search` with any changes.


## Hidden-stage handoff

[Hidden-stage verification](../verification/runs/2026-11-18T225138Z-m6.md) records the matched search/field/delivery diagnostics, fixed-deadline hidden harness, native marker checks, external observer self-test, full-graph memory and idle measurements. It retains missed goals and earlier harness failures. The pipeline extraction does not change ranking. Unchanged file-node writes now preserve prepared chunks, reducing the measured rebuild peak; real no-change scans remain visible in the counters. Production keeps the native search field and task delivery because the matched controls do not show a consistent gain from replacing them.

[DEC-049](../decisions.md#round-12-2026-11-19) now defines the on-screen boundary: wait for Claude’s explicit “on-screen window open” after the user says they are away. No visible run, Screen Recording preflight or capture has happened in the hidden stage. Live callback/observer integration, the key-window watchdog, scale/composition calibration, frame cadence, cold/warm presentation, capture perturbation, and the opaque/vibrancy comparison remain for that stage. The desktop-independent window filter must first prove it represents the required live composition; otherwise bring the alternative to Claude. Hidden view-state results do not qualify DEC-008’s displayed-frame budgets.
