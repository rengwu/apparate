---
title: Fuzzy matching analysis
section: Research
updated: 2026-11-18
---
# Fuzzy matching analysis

Supporting analysis for the [report](report.md). The [benchmark](benchmark.md) contains local measurements and complete reproduction code.

## What must match

`VSC` must match **V**isual **S**tudio **C**ode without a manually configured alias. This is ordered-subsequence matching with word-boundary bonuses; ordinary edit-distance matching is a different problem. Case-insensitive matching should remain the default even when the user types an uppercase acronym. Preserve boundaries from the original string before folding case.

The ranking contract should put exact and prefix matches ahead of scattered matches, recognize word initials and camel-case humps, and use history without letting an unrelated frequently used item dominate. No single scorer provides asynchronous result stability: that belongs to the query/UI pipeline.

## Algorithm comparison

In this table, `m` is query length and `n` is candidate length. **Verified—source** except where marked otherwise. These are algorithm properties, not head-to-head timing results.

| Algorithm | Mechanics and cost | Fit for Apparate |
| --- | --- | --- |
| fzf v1 | Forward subsequence scan, then backward tightening. O(n), but only considers the first discovered occurrence; may miss a better later alignment. | Good bounded fallback for huge candidates. Weak default when match quality matters. |
| fzf v2 | Modified Smith–Waterman-style DP; boundary/camel-case/consecutive bonuses and affine-like gap penalties. O(n) rejection; O(mn) matching; matrix allocation/slab limits lead to v1 fallback. | Strong reference for launcher-quality matching, but copy neither its terminal UI nor all allocations. |
| fzy | Ordered-subsequence precheck; DP tracks best score and best score ending at each position. Consecutive, slash, word-start, camel-case, and dot bonuses; leading/internal/trailing gap penalties. O(mn), score-only rolling rows O(n). | Small, understandable Swift implementation; best first implementation here. Original C code has a 1,024-character cap, which should not become a silent path-search cap. |
| nucleo | Rust matcher used by Helix; fzf-like scoring with improved DP, narrowed rolling rows, aggressive ASCII prefilters, reusable buffers, Unicode preprocessing, and greedy fallback for long inputs. High-level picker also handles parallel work/snapshots. | Best optimization reference; using it directly adds Rust/FFI/build integration. Benchmark the Swift version before choosing that cost. |
| SkimMatcherV2 | Rust DP with separate match/skip states, configurable bonuses and gap penalties, cached buffers, cheap subsequence check, and size-limited fallback. | Useful scoring tests/reference. Current skim contains several engines, so “skim” alone is not a precise algorithm/version. |
| Sublime Text | Official docs confirm fuzzy navigation/completion, but proprietary scoring source is unavailable. The often-cited `lib_fts` is an independent approximation with recursion limits and bonuses for adjacent, separator, and camel-case matches. | Behavioural inspiration. Do not call `lib_fts` Sublime's source or assume exact parity. |
| VS Code `fuzzyScore` | DP with subsequence precheck and feasible-position bounds; rewards prefix/boundaries/case, penalizes gaps, records traceback. Defaults reject a weak first match; callers can relax this. Current function clamps inputs to 128 UTF-16 units and uses shared tables. | Useful relevance cases; a direct long-path port would silently lose coverage. Use worker-local buffers and a deliberate length strategy. |

Source paths: [fzf algo.go](https://github.com/junegunn/fzf/blob/4499615fe9c06c0651aa5650e5d0d0a5face99a8/src/algo/algo.go); [fzy match.c](https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/src/match.c), [fzy limits](https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/src/match.h), [fzy algorithm](https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/ALGORITHM.md); [nucleo design](https://github.com/helix-editor/nucleo/blob/8c16d47cdfa9607d3e44df5f81c635c6f43c65ee/README.md), [nucleo matcher](https://github.com/helix-editor/nucleo/blob/8c16d47cdfa9607d3e44df5f81c635c6f43c65ee/matcher/src/lib.rs); [SkimMatcherV2](https://github.com/skim-rs/skim/blob/daa87145159c161f6202d97b1ea76b40b003c704/src/fuzzy_matcher/skim.rs), [skim engine selection](https://github.com/skim-rs/skim/blob/daa87145159c161f6202d97b1ea76b40b003c704/src/engine/fuzzy.rs); [Sublime documentation](https://www.sublimetext.com/docs/indexing.html), [independent lib_fts implementation](https://github.com/forrestthewoods/lib_fts/blob/d541eb49b289a03320fb62150b8fd01364e22403/code/fts_fuzzy_match.h); [VS Code filters.ts](https://github.com/microsoft/vscode/blob/6e57ff527892780e13d38b3ef961d8377f8ed34a/src/vs/base/common/filters.ts).

Nucleo publishes a Linux-kernel microbenchmark and a deliberately unscientific large-list demonstration. Those are **author-reported**, with a different machine/workload; they do not establish a fixed multiplier over current fzf/skim on this Mac. No head-to-head local comparison was run.

## Alfred and Raycast

**Verified—official docs.** Alfred supports matching application capital letters (`gc` for Google Chrome) or a broader fuzzy mode starting at word boundaries. Its closed source does not establish a particular DP formula. [Alfred default results](https://www.alfredapp.com/help/features/default-results/).

Raycast documents exact alias, alias prefix, title fuzzy score, subtitle/keywords, then frecency as root-search priorities, and learns selections associated with a query. Root-search sensitivity is configurable. This confirms product behaviour, not its proprietary scoring implementation or a proven `VSC` case on this machine. [Raycast search bar](https://manual.raycast.com/search-bar), [aliases](https://manual.raycast.com/command-aliases-and-hotkeys).

## Recommended ranking contract

**Recommendation—not implemented.** Parse the configurable mode prefix first. Then evaluate only that mode's candidates.

1. Exact explicit alias or exact displayed name.
2. Display-name prefix.
3. Word-prefix/acronym alignment, including `VSC`, `gc`, and camel-case humps.
4. Other contiguous display-name matches.
5. General subsequence matches.
6. Secondary keywords/path matches, with lower priority than comparable title matches.

Within a tier, combine normalized text quality with a **bounded** usage term, then deterministic folded name and stable ID. One candidate formula is `text + λ × min(1, log1p(decayedUses)/log1p(20))`, with a small λ calibrated on examples. Decay uses a fixed half-life, initially 30 days; successful launches add one. This formula/half-life is a proposal, not copied behaviour from Alfred/Raycast. Learn query-specific preferences as well as general usage, with a reset action. Capture one history/time snapshot per query so results do not drift while visible.

Separate alias and title sub-priorities if users require aliases always to win. Basename matches should normally outrank matches solely in a parent folder. If the query contains `/`, switch to path-oriented matching; document that syntax rather than sometimes hiding path matches behind a result cap.

A strict tier system intentionally chooses predictability over a single global fuzzy score. Confirm the order with golden examples, including duplicate app names, Calculator/Calendar, `VSC`, `code`, accented names, non-Latin names, and filename extensions.

## Prevent results from jumping

- Search a consistent index generation; compute top results before publishing one batch for a keystroke. Stable sorting cannot fix different providers publishing partial lists at unrelated times.
- Cancel obsolete work and check a monotonically increasing query ID before publication. Do not let a result for `v` overwrite `vsc`.
- When the user moves selection, track the selected stable ID through updates. Enter must activate the displayed selection, not a newly ranked unseen item.
- Keep row height, icon space, and list geometry stable. Replace placeholders without moving text.
- Deterministic ordering for the same query/snapshot is required; unchanged ordering across different queries is not. Better evidence as the user types should be allowed to change ranking.
- Appending query characters permits filtering the prior **complete match set**. Filtering only the previously shown top 10 can lose newly relevant matches. Backspace, mode/root changes, normalization changes, and index updates invalidate that optimization.

## Recommendation after measurement

Use a score-only fzy-like DP in Swift, prepared basename/name buffers, a cheap 64-bit character mask, ordered-subsequence rejection, and reused scratch rows. Compute highlight positions only for displayed results. Use a Unicode-aware path for non-ASCII input with a mapping back to original display graphemes; the benchmark's byte folding is not sufficient for production.

At 200,000 candidates, the measured basename+mask workload took 0.20–6.31 ms per query; full-path+mask took 0.47–80.82 ms. Search fields and workload selectivity matter more here than the mere choice of a fuzzy algorithm. These numbers exclude sorting, top-K selection, IPC, drawing, icon loading, and index refresh. See the [full method and results](benchmark.md).

Keep the small app/settings corpus independent of file search, use bounded top-K selection, and add path narrowing when necessary. Do not put a contiguous-trigram requirement in front of an acronym scorer: `vsc` is not a substring of “Visual Studio Code”. Do not use a broad two-stage top-K shortlist unless its recall is proven; a fast prefilter must not discard the correct match.
