---
title: Requirements
section: Planning
updated: 2026-11-18
status: Accepted
---
# Requirements

Stated by the user on 2026-11-18. Apparate is a minimal Spotlight replacement for macOS, in the spirit of Raycast and Alfred. The motivation is that Spotlight is too slow.

| ID | Requirement | Notes |
| --- | --- | --- |
| REQ-001 | Launch apps. | |
| REQ-002 | Fuzzy matching, including acronyms. | Example: `VSC` launches Visual Studio Code. |
| REQ-003 | Open files and folders in selected directories. | The user chooses which directories are searched. |
| REQ-004 | Open System Settings items, including sub-items. | Example: Spotlight's "Keyboard layouts" result, which opens a specific section of Keyboard settings. |
| REQ-005 | Prefix-controlled commands, configurable in settings. | Example: `'` searches only files and folders; `.` searches only settings items. |
| REQ-006 | Very fast: almost no delay and no shifting of results. | Results should not jump around as they arrive. |
| REQ-007 | Minimal resource and performance footprint. | Memory, CPU and energy use while idle and while searching. |

Added from the user's notes in the round-1 form, 2026-11-18:

| ID | Requirement | Notes |
| --- | --- | --- |
| REQ-008 | Users can add folders to index and set a maximum folder depth. | Beyond the default folders in [DEC-005](decisions.md). |
| REQ-009 | Web search, opened in the default browser. | Trigger and engine are open. |
| REQ-010 | System commands: Lock, Sleep, Restart, Show Trash. | |

These are requirements, not implementation or verification claims. Accepted design choices are in [decisions](decisions.md).

The user also asked for research on how existing launchers achieve their speed and index files ([research](index.md#research)), and for suggestions for additional features.
