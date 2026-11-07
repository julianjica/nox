<p align="center"><img src="docs/icon.png" width="128" alt="nox icon"></p>

# nox

A keyboard-driven PDF viewer for macOS.

nox inherits the idea behind [Sioyek](https://sioyek.info): a PDF viewer for reading research papers and
textbooks, driven from the keyboard. It focuses more on being a **native Mac app** (built on Apple's PDFKit, the engine inside
Preview), on keeping **highlights and notes inside the PDF itself**, and on the **LaTeX + Neovim** writing loop.
It shares no code with Sioyek; the two can share the same notes scripts.

## Features

- **Vim-style keys** for everything: scrolling, pages, marks, search, zoom.
- **Dark mode for pages**: white paper becomes near-black, black ink becomes light; `,c` (or F8) toggles.
  Colors can be changed in `~/.config/nox/theme.json` (see [Colors](#colors)).
- **Highlights and notes saved in the PDF** as standard annotations, so Preview, Acrobat, Zotero and Skim see them too.
  Five highlight colors, notes on highlights, sticky notes, a list of all of them (`gn`).
- **Select text without the mouse** (`v`): every visible line gets a label; type one, then extend by word or line.
- **Presentation mode** (`p`): full-screen slides, presenter view (current and next slide, timer, clock) on the laptop
  when a second display is connected; works with presentation clickers.
- **Table of contents** (`t`) and **link hints** (`f`): follow citations and references from the keyboard.
- **SyncTeX**: `nox main.pdf --forward LINE main.tex` shows where a source line ended up; Shift-click jumps back to the
  source in Neovim (via VimTeX).
- **Auto-reload** when the file changes (LaTeX recompiles), keeping your place. Each PDF reopens where you left it.
- `?` shows every key; after a prefix key (`h`, `g`, `,` …) the status bar lists what can follow.

## Requirements

- macOS 13 or later, Apple silicon or Intel
- Swift 5.9+ (Xcode or the Command Line Tools: `xcode-select --install`)
- Optional: [`qpdf`](https://qpdf.sourceforge.io) (`brew install qpdf`) — nox uses it to tidy the files it saves
- Optional: Neovim + VimTeX for SyncTeX, and a notes script for `,q` / `,n` (see below)

## Install

```sh
git clone https://github.com/julianjica/nox.git ~/nox
sh ~/nox/scripts/build.sh
```

This builds `build/nox.app` and installs a `nox` command in `~/.local/bin` (make sure it is on your `PATH`).
nox registers as an *alternate* PDF app; it never makes itself the default. To make it the default, choose
*Get Info → Open with → nox → Change All…* on any PDF.

## Command line

```sh
nox paper.pdf                         # open (or focus, if already open)
nox paper.pdf --page 12               # open at page 12
nox main.pdf --forward 120 main.tex   # SyncTeX: show where line 120 of main.tex ended up
nox --help                            # all options and keys
```

## Keys

```
Move
  j / k                  scroll down / up (counts work: 5j)
  Ctrl-d / Ctrl-u        half a screen down / up
  Space, Ctrl-f / Ctrl-b a screen down / up
  J / K                  next / previous page
  gg / G / 12G           first page / last page / page 12
  :                      go to a page (type its number)
  Ctrl-o / Ctrl-i        back / forward after following a link
  m{a-z} / '{a-z}        set a mark / jump to it
  t                      table of contents (j/k, ↩ go)
  f                      label the links on screen; type one to follow it (Ctrl-o back)

Search
  /                      search
  n / N                  next / previous match
  Esc                    clear search highlights

Select text without the mouse
  v                      label every visible line; type a label to start there (or start at the search match)
  V                      same, selecting whole lines
  w / b / e              next word / previous word / end of word
  j / k                  line down / up
  0 / $                  start / end of the line
  o                      move the other end of the selection
  then                   ha–he highlight · a note · y copy · ,q quote · Esc cancel

Highlights and notes (saved in the PDF)
  h{a-e}                 highlight the selection: a yellow, b green, c cyan, d pink, e orange
  a                      note on the selection, or a sticky note where you last clicked
  e                      edit the note you last clicked
  dh                     delete the highlight / note you last clicked
  gn                     list all highlights and notes (↩ go, e edit, d delete)
  click / right-click    a highlight: its note and actions / menu

View
  + / - / w              zoom in / out / fit width
  ,c or F8               dark mode on / off
  ,f                     full screen
  s                      two-page spread on / off
  y or Cmd-C             copy the selection

Presentation
  p                      present from this page: full screen; presenter view on a second display
  → Space j / ← k        next / previous slide (clickers work); click / right-click too
  b or .                 blank the screen
  12 ↩                   go to slide 12
  r / t                  restart / pause the timer
  Esc or q               stop presenting (back to the slide you were on)

LaTeX and the notes file
  Shift-click            jump to the LaTeX source in Neovim (SyncTeX)
  ,q                     quote the selection into <file>.notes.md
  ,n                     open <file>.notes.md in Neovim

Files
  r / o / q              reload / open another PDF / close
  ?                      this list
```

## How notes are stored

- A note on a highlight is the highlight's comment; a sticky note is a PDF "text" annotation.
- When saving, nox rebuilds the file from the copy on disk and replaces annotations only on the pages you changed,
  so the recolored display never reaches the file. The result is cleaned with `qpdf` when available and replaces
  the original only once fully written. If the file changed on disk in the meantime, nox refuses to save and asks
  you to reload.

## Colors

Dark mode and the interface use nox's own palette. To change it, create `~/.config/nox/theme.json` with any of these
keys (hex colors); missing keys keep their defaults:

```json
{
  "background": "#141414",
  "darker": "#0B0B0B",
  "selection": "#3A3A3A",
  "comment": "#8C8C8C",
  "foreground": "#E6E4DF",
  "accent": "#8C9EFF",
  "green": "#7CE38B",
  "red": "#FF6B6B",
  "highlight_a": "#FFE45C",
  "highlight_b": "#7CE38B",
  "highlight_c": "#6CD4FF",
  "highlight_d": "#FF7AB6",
  "highlight_e": "#FFAE57"
}
```

`background` is the page paper and `foreground` the ink in dark mode; `highlight_a` … `highlight_e` are the colors of
`ha` … `he`. Restart nox after editing.

## Using it from VimTeX

In your Neovim config:

```lua
vim.g.vimtex_view_method = "general"
vim.g.vimtex_view_general_viewer = vim.fn.expand("~/.local/bin/nox")
vim.g.vimtex_view_general_options = "@pdf --forward @line @tex"
```

Shift-click in nox runs `nvim --headless -c "VimtexInverseSearch …"`, which jumps the running Neovim to the source line.

## Notes file bridge (`,q` / `,n`)

`,q` sends the selected text and `,n` opens a `<file>.notes.md` next to the PDF, through the script
`~/.config/sioyek/scripts/pdfnotes.sh` (shared with Sioyek). The script is not part of this repository; without it,
these two keys do nothing. Notes saved *inside* the PDF (`a`, `h{a-e}`) need no script.

## Development

- `Sources/nox/` — `DocumentController.swift` (window, keys, highlights, notes, saving, reload, selection),
  `Presentation.swift`, `NoteEditor.swift`, `NotesList.swift`, `Picker.swift` (sheets), `Overlay.swift` (live highlight
  drawing), `NoxPage.swift` (dark-mode page drawing), `Keymap.swift` (the key list), `External.swift` (SyncTeX, notes script),
  `AppDelegate.swift`, `main.swift`
- `scripts/build.sh` — build and install; `scripts/make-icon.swift` — draws the app icon
- Testing without the mouse: `nox file.pdf --keys "12G"`, `--search TEXT`, `--note TEXT`, `--state out.json`
  (a JSON snapshot of the window), `--snapshot out.png` (a picture of the window)
