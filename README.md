# Notchy

A macOS menu bar manager for notched MacBooks. Keeps status icons from
disappearing under the notch, and folds groups of them away behind a divider
you can open like a folder.

**Status: early work in progress.** Built and tested on macOS 26 Tahoe only.

## What it does today

- Detects status icons that macOS has pushed off screen or under the notch.
- Adds a `‹` divider to the menu bar. Everything to its left can be folded
  away with one click, or automatically when icons run out of room.
- Shows folded icons in a panel, with their real glyphs. Clicking one
  temporarily expands the section, clicks the icon, and folds it back once
  its menu closes.

## Planned

- Named folders (several dividers), like folders in a browser bookmark bar.
- Remembering which icon belongs to which folder across launches.
- Onboarding for permissions.

## Requirements

- macOS 26.0 or later
- Accessibility permission (required, used to identify icon owners and to
  move them)
- Screen Recording permission (optional, used to show icon glyphs in the panel)

## Build

Open `Notchy.xcodeproj` in Xcode 26 and run. Not sandboxed, not App Store
compatible: it relies on private window server calls and synthesised events.

## How it works

On macOS 26 every status item window belongs to Control Center, so the app
matches window server windows to each app's `AXExtrasMenuBar` items by
position to learn who owns what. Hiding uses the classic spacer trick (a
status item stretched to 10 000 pt). Moving and clicking other apps' icons
synthesises the ⌘-drag a user would do, relayed through per-process event
taps. Much of this approach is borrowed from [Ice](https://github.com/jordanbaird/Ice).

## License

MIT
