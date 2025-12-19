# TypeCheck.nvim

A plugin to practice your typing on code that actually matters: your own. Instead of random words, you type through the vibe code you never bothered to read. Or go big and type the Neovim manual. Happy typing!

## Features

- Type directly over the current buffer with a ghost-text guide.
- WPM + accuracy in the floating window title.
- Progress line shown in the window bar.
- Auto-skip separator lines.
- Session progress saved and restored across restarts.
- `:TypeCheckStats` floating window for per-file stats and overall Neovim manual progress.

## Installation (lazy.nvim)

```lua
{
  "casni14/TypeCheck.nvim",
  cmd = { "TypeCheck", "TypeCheckStats" },
}
```

## Usage

Open any file you want to practice and run:

```
:TypeCheck
```

Quit the practice window with `q`.

See saved stats with:

```
:TypeCheckStats
```

## Help

Run `:h TypeCheck` after generating helptags (most plugin managers do this).

## Notes

- Progress is stored in `stdpath("state")/typecheck_progress.json`.
- Saved sessions resume at the next character.
- The Neovim manual progress line aggregates your typing across `$VIMRUNTIME/doc/*.txt`.
