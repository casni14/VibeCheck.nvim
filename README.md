# VibeCheck.nvim

A plugin to practice your typing on code that actually matters: your own. Instead of random words, you type through the vibe code you never bothered to read. Or go big and type the Neovim manual — see you on the other side.

## Features

- Type directly over the current buffer with a ghost-text guide.
- WPM + accuracy in the floating window title.
- Progress line shown in the window bar.
- Auto-skip separator lines.
- Session progress saved and restored across restarts.
- `:VibeCheckStats` floating window for per-file stats and overall Neovim manual progress.

## Installation (lazy.nvim)

```lua
{
  "VibeCheck.nvim",
  dir = vim.fn.stdpath("config"),
  cmd = { "VibeCheck", "VibeCheckStats" },
  config = function()
    vim.api.nvim_create_user_command("VibeCheck", function()
      require("vibecheck").start()
    end, {})

    vim.api.nvim_create_user_command("VibeCheckStats", function()
      require("vibecheck").stats()
    end, {})
  end,
}
```

## Usage

Open any file you want to practice and run:

```
:VibeCheck
```

Quit the practice window with `q`.

See saved stats with:

```
:VibeCheckStats
```

## Notes

- Progress is stored in `stdpath("state")/vibecheck_progress.json`.
- Saved sessions resume at the next character.
- The Neovim manual progress line aggregates your typing across `$VIMRUNTIME/doc/*.txt`.
