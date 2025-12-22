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
  opts = {
    auto_skip_separators = true, ---  specifically to skip the seperators in help files
  },
}
```

Lazy.nvim loading styles:

```lua
-- Load immediately on startup
{
  "casni14/TypeCheck.nvim",
  lazy = false,
}

-- Load on a generic event
{
  "casni14/TypeCheck.nvim",
  event = "VeryLazy",
}
```

## Installation (packer.nvim)

```lua
use({
  "casni14/TypeCheck.nvim",
  config = function()
    require("typecheck").setup({
      auto_skip_separators = true,
    })
  end,
})
```

## Installation (vim-plug)

```vim
Plug 'casni14/TypeCheck.nvim'

lua << EOF
require("typecheck").setup({
  auto_skip_separators = true,
  daily_goal_minutes = 30,
})
EOF
```

## Installation (manual)

```vim
set rtp+=/path/to/TypeCheck.nvim
```

## Usage

Open any file you want to practice and run:

```
:TypeCheck
```

Quit the practice window with `q`.

Leading indentation is kept aligned with the source line by default so the ghost text stays fixed.

See saved stats with:

```
:TypeCheckStats
```

## Configuration

Defaults:

```lua
require("typecheck").setup({
  auto_skip_separators = true,
  daily_goal_minutes = 30,
  auto_indent = true,
})
```

Options:

- `auto_skip_separators` (boolean): skip lines made of repeating symbols while navigating.
- `history_size` (number): max number of recent sessions to keep for stats trends.
- `daily_goal_minutes` (number): daily active typing goal shown in stats (minutes).
- `auto_indent` (boolean): keep typed indentation aligned with the source line.

## Help

Run `:h TypeCheck` after generating helptags (most plugin managers do this).

## Notes

- Progress is stored in `stdpath("state")/typecheck_progress.json`.
- Saved sessions resume at the next character.
- If the source file changes, progress is remapped line-by-line when possible.
- The Neovim manual progress line aggregates your typing across `$VIMRUNTIME/doc/*.txt`.

## TODO / Ideas

- [ ] smart pairs positioning
- [ ] repo detection and repo completion status
- [ ] Make the stats interface look better.
