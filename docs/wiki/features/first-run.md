---
title: First run
section: Features
updated: 2026-11-19
---
# First run

**FEAT-first-run.** A single setup window replaces the earlier access-only window. It shows shortcut and protected-folder steps, **Choose Folders…** and **Done**, following [M5](../build/m5-settings-menu-first-run.md#pushback-and-answers).

## Entry points and expected outcomes

Eligibility is captured before ConfigStore writes defaults: missing config shows setup and existing config does not. In testing builds only, `APPARATE_SHOW=setup` is an explicit override; M7 excludes that switch from production. Done closes even when steps are incomplete. It neither shows the launcher nor quits; the newly created config prevents repeated onboarding next launch.

The shortcut step completes only when Apparate holds the configured key and, for ⌘Space, Spotlight is known not to use it. A different registered shortcut completes the step too. Unknown Spotlight state asks the user to check, without claiming a conflict or success. Known first-run Spotlight conflict uses the inline explanation; other unexpected startup registration failure retains the one-time alert. Returning to either preferences window rereads shortcut/login/config state and retries registration.

The [UI follow-up](../build/ui-follow-up.md) (DEC-051) keeps the checklist and removes redundant shortcut success text, per-folder “Not checked”, the all-allowed summary and the Projects permission claim. Checkmarks carry success. Plain, nonselectable status labels wrap and the window height follows the content. The shortcut conflict/unavailable guidance, checking progress and named denied/missing/error outcomes remain.

The access step says “macOS may ask for access to each folder.” Only **Allow Access…** probes Desktop, Documents and Downloads, sequentially. Focus refresh never probes. Saved results are last-check hints; denied, missing and error states remain separate. Closing the checking window cancels future probes in that sequence; an already issued system prompt cannot be dismissed by the app. Done is always available. **Choose Folders…** routes to the same Settings window's Folders tab. Settings offers a conditional access retry after setup has closed.

## Verification recipe

Use [M5 setup](../verification/setup.md#m5-settings-menu-and-setup). Core fixtures check unknown/conflicting/free/custom shortcuts, sequential probes, partial outcomes, cancellation, saved hints and no probes on focus refresh. Hidden native checks render setup in light/dark and partial states, check eligibility, Choose Folders routing and Done while incomplete. The normal app fixture graph separately renders setup with fake access results.

## Supervised recipes — Untested

Use a fresh, agreed development config and explicitly agreed privacy actions. Confirm setup appears once, can be closed incomplete and does not return next launch. Check the real shortcut link, return-to-window refresh, one-time unexpected registration error and custom shortcut success. Check mixed folder decisions, close during a pending check, reopen and retry through Settings, then rebuild with the same signed identity and verify persistence. Restore agreed preferences afterward. See the existing [M2 supervised recipe](../verification/runs/2026-11-18T164001Z-m2-supervised.md). These checks remain Untested; [DEC-061](../decisions.md#round-13-2026-11-19) waives them for release 0.1.0.

## Coverage and limitations

No automated check launches System Settings, presents a window, changes login registration or privacy grants, writes symbolichotkeys or reads protected user folders. Saved Allowed observations are not evidence of a current TCC grant. Actual macOS prompts, keyboard focus and composed window appearance remain Untested.

## Verification history

- [M5 automated verification](../verification/runs/2026-11-18T212428Z-m5.md).

- [UI follow-up verification](../verification/runs/2026-11-19T064952Z-ui.md) — hidden incomplete, partial and complete light/dark setup states.

- [Result-location follow-up verification](../verification/runs/2026-11-19T085025Z-row-location.md) — unchanged setup eligibility, actions and incomplete/partial/complete light/dark states re-exercised with the new Settings control.

New configs now include shallow home/root discovery as well as the original four folders (DEC-054); existing lists stay intact. Setup’s explicit access checks are unchanged. [Section 5 verification](../verification/runs/2026-11-19T095817Z-path-folders.md).
