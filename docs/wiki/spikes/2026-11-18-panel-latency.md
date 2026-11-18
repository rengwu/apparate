---
title: Panel latency spike
section: Spikes
updated: 2026-11-18
status: Complete
---
# Panel latency spike

Run by Claude on 2026-11-18, after the user asked to move the next steps forward. Codex reviewed it the same day. Its corrections are applied below, and the [known flaws](#known-flaws-in-the-harness) section lists its findings about the method. The code is a throwaway test program, not product code.

## Question

Can the agreed design ([DEC-013](../decisions.md#round-2-2026-11-18)) meet the performance budgets ([DEC-008](../decisions.md#round-1-2026-11-18))? If not, what stands in the way?

## Answer

The numbers below are indicative, not pass or fail, because the harness has known flaws.

- **Memory and idle CPU:** well inside the budgets in this harness. The harness has no SQLite, FSEvents, real paths or settings UI, and its readings are end points, not peaks.
- **Search:** small in this workload. 20k items took 0.3 / 1.7 ms (median / p95). 200k items on 4 threads took 2.4 / 10.2 ms, with a maximum of 14 ms.
- **Time to screen:** no variant met the display budgets in this harness. An empty panel measured the same way took 33 ms median and 44 ms p95 to appear. That suggests the "hotkey → first frame ≤ 33 ms p95" limit may be hard to meet for any AppKit panel, but one run of an imperfect harness is not a proven floor.
- **Drawing:** in this spike's table-view rows built with Auto Layout, layout and drawing took about 23 ms median per update. Nine rows drawn directly with Core Text took 1–2 ms.

## What was built

- A non-activating panel built at launch: 640 × 334 pt, 9 rows of 28 pt, search field and footer, as in [DEC-023](../decisions.md#round-3-ui-design-spike-2026-11-18).
- An index of real names: the apps and settings items on this Mac plus about 22,000 file and folder names from `~/Projects`, repeated to reach 200,000. The kinds and locations are synthetic, and matching folds ASCII only.
- Search on a serial background queue with generation IDs. The scorer is the one from the [research benchmark](../research/claude/benchmark.md), with match tiers and kind order added. It keeps the best 50.
- Typing through the panel's real text field: key events go through the field editor (55 of 55 keys arrived).

## Method

- MacBook Pro M1 Pro, macOS 27.0, built-in 120 Hz display.
- The panel was shown and hidden 30 times. Then 10 words (55 keys) were typed, and finally a burst of 12 keys.
- The driver waited for each key's results, up to 200 ms, before pausing 220 ms (or 60 ms) and sending the next key. So keys were not evenly spaced, and the burst did not really overlap searches.
- **In-app time:** from the start of the show or the key event to the end of an explicit `CATransaction.flush`. Forcing the flush is part of the experiment; an app would normally let the run loop commit.
- **On-screen time:** ScreenCaptureKit recorded the panel's screen area.
  - The figure is the WindowServer display time of the first captured frame with enough changed pixels. For results, it is the last such frame before the next key.
  - This is not the moment light leaves the display. The capture rate was requested, not guaranteed.
- **Memory:** `phys_footprint`. **Idle CPU:** CPU time used over 5 s with the panel hidden.
- **Not measured:**
  - the time from a physical key press to the hotkey callback;
  - crawling, SQLite and FSEvents.

## Results

20,000 items unless noted. Times in ms, written as median / p95. Each row is a single run, with n = 30 shows and 55 keys. With n = 55, p95 is the 52nd of 55 sorted values.

| Variant | Show → committed | Show → on screen | Key → letter and results committed | Key → results on screen |
| --- | --- | --- | --- | --- |
| Empty panel, for comparison | 12.0 / 19.3 | 33.0 / 44.3 | — | — |
| Table view with Auto Layout rows | 13.7 / 21.2 | 33.5 / 50.2 | 41.8 / 55.7 | 56.8 / 72.5 |
| 9 rows drawn directly | 16.4 / 20.0 | 40.4 / 59.2 | 21.6 / 31.7 | 35.1 / 69.6 |
| … plus Core Text, and the field waits up to 4 ms for search | 14.8 / 21.5 | 33.7 / 49.3 | 17.8 / 26.3 | 32.3 / 46.7 |
| Same, without screen recording | 15.9 / 20.4 | not recorded | 10.4 / 16.3 | not recorded |
| Same, opaque background instead of vibrancy | 14.0 / 20.2 | 35.7 / 57.7 | 12.2 / 22.0 | 26.0 / 38.8 |
| Same, keys 60 ms apart | — | — | 11.2 / 19.9 | 24.9 / 39.0 |
| Same, 200,000 items | 13.5 / 20.3 | 34.4 / 58.8 | 15.1 / 27.6 | 28.5 / 49.2 |

Notes:

- Show results vary by about 10 ms between runs.
- The "results on screen" maximums of 250–390 ms come from the harness. After the last word, its detection window included the field being cleared.
- The variant with Core Text and the 4 ms wait changed two things at once, so it does not show what the wait alone did. Its typed letter reached the screen later (32 ms median) than in the drawn-rows run with neither change (24.5 ms), in single runs.
- The best variant without recording was 16.3 ms p95 from key to commit, just above the 16 ms limit. That is in-app time only.
- Screen recording slowed the app. The same variant took 10.4 ms median without it and 17.8 ms with it, in separate single runs.

Medians per stage for the best variant without recording. The stages have different sample sets: 55 keys, 67 searches and 78 updates. They do not add up to a total.

| Stage | Median / p95, ms |
| --- | --- |
| Ordering the panel front (`makeKeyAndOrderFront`) | 13.6 / 15.9 |
| Key event → text-change callback | 1.2 / 2.1 |
| Search, 20k items | 0.3 / 1.7 |
| Building the 9 rows | 1.3 / 2.3 |
| Layout and draw | 1.3 / 2.0 |
| Forced Core Animation commit | 5.2 / 10.0 |

Memory (`phys_footprint`, MiB):

| Items | Index loaded, panel built | After 30 shows, before typing | End of run, after typing |
| --- | --- | --- | --- |
| 20,000 | 14 | 19–21 | 29 (no recording) |
| 200,000 | 45 | 42 | 51 (includes recording buffers) |

Idle CPU with the panel hidden was 0.025% over 5 s, without recording.

The first show after launch took 42–49 ms to commit, against about 15 ms when warm. In the very first run, it took 216 ms; see the [first-run report](../attachments/2026-11-18-panel-latency/run-20k-first-run.txt).

## Known flaws in the harness

Found by Codex's review. A later, authorized run must fix these before any result is treated as a verdict.

- **Detection:** the pixel-change detector does not check which result generation, text or selection is on screen. Missed detections were dropped instead of counted, and the show window had no upper bound.
- **Data races:** the generation counter and the stage-timer dictionary were shared between threads without synchronization.
- **Forced commits:** an explicit flush on every update is not how the app would normally run.
- **Uneven keys:** keys were sent after results arrived, not at fixed times, so stale-result handling under overlap was not tested.
- **Warm-up:** the spike's warm-up showed the panel and took keyboard focus for 300 ms. A hidden warm-up was not tested.
- **Records:** there are no per-event records, so the percentiles and outliers cannot be audited.

## What this means for the build

1. **Budgets.** The user kept DEC-008 as provisional end-to-end goals, to be measured properly in M6 and then revisited ([DEC-028](../decisions.md#round-4-2026-11-18)). Codex had recommended this, and Claude agreed.
2. **Rows.** A custom Core Text list is a candidate, not a decision. It must keep keyboard and mouse selection, VoiceOver, and results past the ninth. In M4 it is compared with manually laid-out table cells.
3. **Publishing results.** Publish one complete result set per query generation. Never show partial sources or stale results, and keep the selection on the same item. The typed letter shows immediately; waiting on the main thread is not adopted, and can be tested in M4.
4. **Warm-up.** Find a warm-up that does not take focus, and check that it helps.
5. **Vibrancy.** In single runs it cost about 5 ms per key against an opaque background. Revisit it if the budgets are missed.

## Evidence

- Source, SHA-256 `9e241ec3…94ad`: [spike source](../attachments/2026-11-18-panel-latency/spike.swift.txt).
  - It is the final revision and has all variants behind flags.
  - Earlier runs used earlier revisions with the same code paths for their flags.
  - The [first-run source](../attachments/2026-11-18-panel-latency/spike-first-run.swift.txt) adds stage timers that the first run did not have; the exact first-run source was not kept.
- Run reports:
  - [Table view](../attachments/2026-11-18-panel-latency/run-20k-table.txt)
  - [Drawn rows](../attachments/2026-11-18-panel-latency/run-20k-fast.txt)
  - [Core Text and wait](../attachments/2026-11-18-panel-latency/run-20k-fast-ct-sync.txt), and [without recording](../attachments/2026-11-18-panel-latency/run-20k-best-nocapture.txt)
  - [Opaque background](../attachments/2026-11-18-panel-latency/run-20k-fast-ct-sync-opaque.txt)
  - [Keys 60 ms apart](../attachments/2026-11-18-panel-latency/run-20k-fast-ct-sync-i60.txt)
  - [200,000 items](../attachments/2026-11-18-panel-latency/run-200k-fast-ct-sync.txt)
  - [Empty panel](../attachments/2026-11-18-panel-latency/run-20k-minimal.txt)
  - [First run](../attachments/2026-11-18-panel-latency/run-20k-first-run.txt)

## Limits

- One machine, single runs per variant.
- Key events were posted inside the app, so the path from keyboard hardware to the app is not included.
- See [known flaws](#known-flaws-in-the-harness).
