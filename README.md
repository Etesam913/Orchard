# Orchard

A macOS terminal workspace app built on [Ghostty](https://ghostty.org)'s
terminal core (`libghostty`, embedded as `GhosttyKit.xcframework`), with a
SwiftUI/AppKit shell.

## Features

- **Projects sidebar** — register project directories; each project gets its
  own workspace of terminal tabs, restored across launches.
- **Tabs and split panes** — arbitrary horizontal/vertical splits per tab
  (`SplitNode` tree), with Ctrl-Tab cycling that commits on Ctrl release.
- **Command palette** — fuzzy palette over commands, projects, and
  directories (`Orchard/Palette/`).
- **Quick terminal** — global drop-down terminal panel
  (`QuickTerminal.swift`), independent of the main window.
- **Diff sidebar** — live git diff of the active project rendered in a
  WebKit-based viewer (`PierreDiffView` + `Resources/DiffViewer.html`) with
  copy and open-in-editor support. Refresh via the **Diff** menu (⌘R by
  default).
- **Terminal search**, rebindable hotkeys (Settings → Keymaps; changes apply
  after app restart), bundled **Orchard / Orchard Light** themes, and
  window-level translucency/blur handled by Orchard itself.
- Quit/close confirmation when a pane still has a running process.

## Requirements

- macOS 26.1+ (deployment target)
- Xcode with Swift 6 toolchain
- `GhosttyKit.xcframework` at the repo root (not committed — see below)

## Building

```sh
# Debug build
xcodebuild -project Orchard.xcodeproj -scheme Orchard -configuration Debug \
  -derivedDataPath build build

# Release build
xcodebuild -project Orchard.xcodeproj -scheme Orchard -configuration Release \
  -derivedDataPath build build

# Run it
open build/Build/Products/Release/Orchard.app
```

Or just open `Orchard.xcodeproj` in Xcode and hit Run. Code signing is
automatic (`etesam.Orchard`).

## GhosttyKit.xcframework

The Xcode project links `GhosttyKit.xcframework` from the repo root. It is a
~540 MB build artifact and is **not** checked in. To produce it, build it
from [Ghostty source](https://github.com/ghostty-org/ghostty):

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build xcframework
cp -R macos/GhosttyKit.xcframework /path/to/Orchard/
```

(See Ghostty's developer docs for the required Zig version; the framework
contains `macos-arm64_x86_64`, `ios-arm64`, and `ios-arm64-simulator`
slices — only the macOS slice is used.)

## Ghostty configuration

Orchard does not replace your Ghostty config — it wraps it. On launch,
`OrchardConfig` writes two files into Application Support and
`GhosttyApp.loadConfig` loads configs in last-wins order:

```
orchard-defaults.conf  →  your own Ghostty config  →  orchard-overrides.conf
```

- **Defaults** (you can override all of these): `theme = "Rose Pine"`,
  `font-size = 12`, `macos-option-as-alt = true`,
  `window-padding-x/y = 16`.
- **Overrides** (always win, required for Orchard's window compositing):
  `background-opacity = 0` and `background-blur = 0` — Orchard draws window
  translucency and blur itself at the AppKit level (`WindowAppearance`).
- Conditional themes (`theme = dark:X,light:Y`) are resolved by Orchard on
  appearance changes and written as a flat override, since libghostty does
  not reliably re-evaluate them.

Everything else in your Ghostty config is honored as-is.

## Project layout

```
Orchard/
├── App/            App entry, state, key routing, hotkeys, preferences
├── Config/         Ghostty config wrapping (defaults/overrides files)
├── Ghostty/        libghostty bridge: app lifecycle, callbacks, themes
├── Model/          Project, Workspace, SplitNode, diff & search state
├── Palette/        Command-palette engine and sources
├── Persistence/    Workspace/project storage (Application Support)
├── Resources/      DiffViewer.html, bundled themes
└── Views/          MainWindow, Sidebar, TerminalPane, QuickTerminal,
                    DiffSidebar, CommandPalette, split tree, search bar
```

`.agents/` and `skills-lock.json` configure the
[swiftui-pro](https://github.com/twostraws/swiftui-agent-skill) agent skill
and are committed intentionally.

## State on disk

- Workspaces and projects: Application Support (saved on quit via
  `WorkspacePersistence` / `ProjectStore`).
- Generated Ghostty wrapper configs: `orchard-defaults.conf`,
  `orchard-overrides.conf` in the same directory.
