local M = {}
local api = vim.api
local apply_indent

-- Cache for resuming sessions
-- [buf_name] = { lines = {}, cursor = {}, elapsed = 0 }
local progress_cache = {}
local progress_cache_path = vim.fn.stdpath("state") .. "/vibecheck_progress.json"

local function load_progress_cache()
  if vim.fn.filereadable(progress_cache_path) ~= 1 then return end
  local ok, lines = pcall(vim.fn.readfile, progress_cache_path)
  if not ok or not lines or #lines == 0 then return end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(decoded) == "table" then
    progress_cache = decoded
  end
end

local function persist_progress_cache()
  local ok, encoded = pcall(vim.json.encode, progress_cache)
  if not ok or not encoded then return end
  pcall(vim.fn.writefile, { encoded }, progress_cache_path)
end

local function compute_correct_typed(target_lines, typed_lines)
  local total_correct = 0
  local total_typed = 0

  local max_lines = math.max(#typed_lines, #target_lines)
  for i = 1, max_lines do
    local user_line = typed_lines[i] or ""
    local target_line = target_lines[i] or ""
    total_typed = total_typed + #user_line
    local max_chars = math.min(#user_line, #target_line)
    for j = 1, max_chars do
      if user_line:sub(j, j) == target_line:sub(j, j) then
        total_correct = total_correct + 1
      end
    end
  end

  return total_correct, total_typed
end

local function compute_stats_for(target_lines, typed_lines, elapsed_s)
  local total_correct, total_typed = compute_correct_typed(target_lines, typed_lines)

  local total_ms = (elapsed_s or 0) * 1000
  if total_ms < 1000 then total_ms = 1000 end
  local mins = total_ms / 60000
  local wpm = math.floor((total_correct / 5) / mins)

  local acc = 100
  if total_typed > 0 then
    acc = math.floor((total_correct / total_typed) * 100)
  end

  return wpm, acc
end

-- State
local state = {
  buf = nil,
  win = nil,
  orig_buf = nil,
  orig_win = nil,
  target_lines = {},
  hl_cache = {},
  ns = api.nvim_create_namespace("VibeCheck"),
  progress_ns = api.nvim_create_namespace("VibeCheckProgress"),
  stats = {
    accumulated_ms = 0,
    active_start = nil, -- nil means paused
    last_type = nil,
    line_counts = {}, -- [row] = count
    timer = nil,
  },
  progress_mark_id = nil,
  config = {
    auto_skip_separators = true, -- New config option
  }
}

-- Highlights
local function set_highlights()
  -- Define highlights if they don't exist
  local function set_hl(name, opts)
    local ok, _ = pcall(api.nvim_get_hl_by_name, name, true)
    if not ok or true then -- Force update for now
       api.nvim_set_hl(0, name, opts)
    end
  end

  set_hl("VibeCheckDim", { link = "Comment" })
  set_hl("VibeCheckCorrect", { link = "String" }) -- Fallback
  set_hl("VibeCheckWrong", { link = "Error" })
  set_hl("VibeCheckCursor", { bg = "#555555", fg = "#ffffff" })
end

-- Helper to check if a line is a separator (repeating punctuation/symbols)
local function is_separator_line(line_idx_0based)
  if line_idx_0based >= #state.target_lines or line_idx_0based < 0 then return false end
  local line_text = state.target_lines[line_idx_0based + 1] or ""
  local stripped_line = line_text:gsub("%s", "") -- Remove whitespace for check
  
  if #stripped_line == 0 then return false end -- Empty line is not a separator
  if #stripped_line < 5 then return false end -- Too short to be a meaningful separator

  local first_char = stripped_line:sub(1, 1)
  -- If the first character is alphanumeric, it's probably code, not a separator
  if first_char:match("[%%a%%d]") then return false end -- Lua patterns: %a for alphabetic, %d for digit
  
  -- Check if all non-whitespace characters are the same as the first one
  return stripped_line:match("^(.)%1*$") ~= nil
end

-- Helper function to calculate where to jump next (skipping separators)
-- direction: 1 for next line (down), -1 for previous line (up)
local function get_next_vibe_pos(start_row_0indexed, direction)
  local target_row_0indexed = start_row_0indexed + direction

  while target_row_0indexed >= 0 and target_row_0indexed < #state.target_lines do
    if state.config.auto_skip_separators and is_separator_line(target_row_0indexed) then
      -- Automatically "type" this separator line
      local sep_line_text = state.target_lines[target_row_0indexed + 1] or ""
      api.nvim_buf_set_lines(state.buf, target_row_0indexed, target_row_0indexed + 1, false, { sep_line_text })
      render_line(target_row_0indexed, sep_line_text) -- Update stats and display
      target_row_0indexed = target_row_0indexed + direction
    else
      -- Found a non-separator line
      local col = apply_indent(target_row_0indexed)
      return target_row_0indexed + 1, col -- Return 1-indexed row, 0-indexed col
    end
  end
  
  -- If we reached end/beginning of buffer without finding a non-separator line,
  -- stay at the last valid position.
  if direction == 1 then -- Moving down
    return #state.target_lines, #state.target_lines[#state.target_lines] or 0
  else -- Moving up
    return 1, 0
  end
end

local function get_origin_hl(row, col)
  if not state.orig_buf then return "VibeCheckCorrect" end
  
  -- Try Treesitter
  local has_ts = false
  if vim.treesitter.highlighter.active[state.orig_buf] then
    has_ts = true
  end
  
  if has_ts then
    -- pcall because get_captures_at_pos might not exist or fail
    local ok, captures = pcall(vim.treesitter.get_captures_at_pos, state.orig_buf, row, col)
    if ok and captures and #captures > 0 then
      -- Use the last capture (most specific)
      local cap = captures[#captures]
      if cap.capture then
        return "@" .. cap.capture
      end
    end
  end
  
  -- Fallback to synID (legacy)
  -- We need to execute in the context of the original buffer
  local hl_name = nil
  vim.api.nvim_buf_call(state.orig_buf, function()
     local synID = vim.fn.synID(row + 1, col + 1, 1)
     hl_name = vim.fn.synIDattr(synID, "name")
  end)
  
  if hl_name and hl_name ~= "" then
    return hl_name
  end
  
  return "VibeCheckCorrect"
end

local function get_cached_hl(row, col)
  if not state.hl_cache[row] then state.hl_cache[row] = {} end
  if not state.hl_cache[row][col] then
     state.hl_cache[row][col] = get_origin_hl(row, col)
  end
  return state.hl_cache[row][col]
end

-- Logic to calculate diff and render
local function render_line(row, user_line)
  if not state.target_lines then return end
  local target_line = state.target_lines[row + 1] or ""
  local chunks = {}
  local correct_chars = 0
  
  -- Iterate through user input
  for i = 1, #user_line do
    local u_char = user_line:sub(i, i)
    local t_char = target_line:sub(i, i)
    
    if t_char == "" then
       -- User typed more than target
       local display = (u_char == " ") and "_" or u_char
       table.insert(chunks, { display, "VibeCheckWrong" })
    elseif u_char == t_char then
       correct_chars = correct_chars + 1
       local hl = get_cached_hl(row, i-1)
       table.insert(chunks, { u_char, hl })
    else
       -- Show what user typed in Red.
       local display = (u_char == " ") and "_" or u_char
       table.insert(chunks, { display, "VibeCheckWrong" })
    end
  end
  
  -- Remaining target text
  if #target_line > #user_line then
    local remaining = target_line:sub(#user_line + 1)
    table.insert(chunks, { remaining, "VibeCheckDim" })
  end
  
  -- Update stats for this line
  state.stats.line_counts[row] = { correct = correct_chars, total = #user_line }
  
  -- Set extmark (replace previous one)
  api.nvim_buf_set_extmark(state.buf, state.ns, row, 0, {
    virt_text = chunks,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    id = row + 1, -- Reuse ID 1-based (row+1)
  })
end

local function on_lines(_, buf, _, firstline, _, new_lastline, _)
  if buf ~= state.buf then return end
  
  vim.bo[buf].modified = true
  
  -- Track activity
  local now = vim.uv.now()
  if not state.stats.active_start then
     state.stats.active_start = now
  end
  state.stats.last_type = now
  
  -- Loop through changed lines
  -- inclusive start, exclusive end for get_lines, so loop 0 to count-1?
  -- if firstline=0, new_lastline=1. Loop 0 to 0. Correct.
  for i = firstline, new_lastline - 1 do
     local lines = api.nvim_buf_get_lines(buf, i, i+1, false)
     if #lines > 0 then
        render_line(i, lines[1])
     else
        render_line(i, "")
     end
  end
end

local function update_title(paused)
   if not state.win or not api.nvim_win_is_valid(state.win) then return end

   local total_correct = 0
   local total_typed = 0
   for _, stat in pairs(state.stats.line_counts) do
      total_correct = total_correct + stat.correct
      total_typed = total_typed + stat.total
   end
   
   local total_ms = state.stats.accumulated_ms
   if state.stats.active_start then
      total_ms = total_ms + (vim.uv.now() - state.stats.active_start)
   end
   
   -- Prevent divide by zero (min 1 sec)
   if total_ms < 1000 then total_ms = 1000 end
   
   local mins = total_ms / 60000
   local wpm = math.floor((total_correct / 5) / mins)
   
   local acc = 100
   if total_typed > 0 then
      acc = math.floor((total_correct / total_typed) * 100)
   end
   
   local status = paused and "PAUSED" or "WPM"
   local title = string.format(" VibeCheck (%s: %d | Acc: %d%%) ", status, wpm, acc)
   api.nvim_win_set_config(state.win, { title = title })
end

local function update_progress_line()
  if state.win and api.nvim_win_is_valid(state.win) then
    local total = #state.target_lines
    if total == 0 then return end

    local cur = 1
    local pos = api.nvim_win_get_cursor(state.win)
    if pos and pos[1] then cur = pos[1] end

    local pct = math.floor((cur / total) * 100)
    local text = string.format(" Progress: %d/%d (%d%%) ", cur, total, pct)
    local winbar = text:gsub("%%", "%%%%")
    api.nvim_win_set_option(state.win, "winbar", winbar)
  end
end

local function check_timer()
   if not state.win or not api.nvim_win_is_valid(state.win) then return end
   
   local now = vim.uv.now()
   
   -- Check pause condition
   if state.stats.active_start then
      if state.stats.last_type and (now - state.stats.last_type) > 2000 then -- 2 seconds timeout
         -- Pause
         local burst = state.stats.last_type - state.stats.active_start
         state.stats.accumulated_ms = state.stats.accumulated_ms + burst
         state.stats.active_start = nil
         
         update_title(true) -- paused = true
      else
         update_title(false) -- paused = false
      end
   else
      update_title(true)
   end
   update_progress_line()
end

local function start_timer()
  state.stats.timer = vim.uv.new_timer()
  state.stats.timer:start(100, 100, vim.schedule_wrap(function()
     if state.win and api.nvim_win_is_valid(state.win) then
        check_timer()
     else
        if state.stats.timer then
           state.stats.timer:stop()
           state.stats.timer:close()
           state.stats.timer = nil
        end
     end
  end))
end

load_progress_cache()

function M.start()
  -- 1. Get current buffer content
  local current_buf = api.nvim_get_current_buf()
  local lines = api.nvim_buf_get_lines(current_buf, 0, -1, false)
  
  state.orig_buf = current_buf
  state.target_lines = lines
  state.orig_win = api.nvim_get_current_win()
  state.hl_cache = {}
  
  set_highlights()
  
  -- 2. Create scratch buffer
  state.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(state.buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(state.buf, 'buftype', 'acwrite')
  api.nvim_buf_set_name(state.buf, "VibeCheck")
  api.nvim_buf_set_option(state.buf, 'filetype', 'vibecheck')
  
  -- Disable distractions (Autocompletion, Diagnostics, AI)
  if vim.diagnostic.enable then
    vim.diagnostic.enable(false, { bufnr = state.buf })
  else
    vim.diagnostic.disable(state.buf)
  end
  
  local ok_cmp, cmp = pcall(require, "cmp")
  if ok_cmp then cmp.setup.buffer({ enabled = false }) end
  
  vim.b[state.buf].minicompletion_disable = true
  vim.b[state.buf].copilot_enabled = false
  -- Note: blink.cmp usually respects 'filetype' exclusion or lack of LSP sources
  
  -- Check cache for resume
  local buf_name = api.nvim_buf_get_name(current_buf)
  local cached = progress_cache[buf_name]
  local start_lines = {}
  local start_cursor = {1, 0}
  local start_elapsed = 0

  if cached and #cached.lines == #lines then
     start_lines = cached.lines
     start_cursor = cached.cursor
     start_elapsed = cached.elapsed or 0

     local line_at_cursor = start_lines[start_cursor[1]] or ""
     if start_cursor[2] < #line_at_cursor then
       start_cursor = { start_cursor[1], start_cursor[2] + 1 }
     end
  else
     for _=1, #lines do table.insert(start_lines, "") end
     -- Ensure at least one line (already handled by loop if #lines > 0)
     if #start_lines == 0 then table.insert(start_lines, "") end
  end
  
  -- Init Stats
  state.stats = {
    accumulated_ms = start_elapsed * 1000,
    active_start = nil, -- Starts paused
    last_type = nil,
    line_counts = {},
    timer = nil,
  }

  api.nvim_buf_set_lines(state.buf, 0, -1, false, start_lines)
  
  -- 3. Create floating window
  local width = api.nvim_get_option("columns")
  local height = api.nvim_get_option("lines")
  
  state.win = api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width - 4,
    height = height - 5,
    col = 2,
    row = 2,
    style = 'minimal',
    border = 'rounded',
    title = ' VibeCheck ',
    title_pos = 'center',
  })
  
  -- Allow navigation into ghost text
  vim.wo[state.win].virtualedit = "all"

  -- Sync line numbers with original window
  if state.orig_win and api.nvim_win_is_valid(state.orig_win) then
     api.nvim_win_set_option(state.win, 'number', api.nvim_win_get_option(state.orig_win, 'number'))
     api.nvim_win_set_option(state.win, 'relativenumber', api.nvim_win_get_option(state.orig_win, 'relativenumber'))
  end
  
  -- 4. Initial Render
  for i = 0, #lines - 1 do
    render_line(i, start_lines[i+1] or "")
  end
  
  -- 5. Attach listener
  api.nvim_buf_attach(state.buf, false, {
    on_lines = on_lines
  })
  
  -- 6. Keymaps
  local opts = { noremap = true, silent = true, buffer = state.buf }
  
  -- Use 'q' to quit from Normal mode
  vim.keymap.set('n', 'q', ':q<CR>', opts)
  
  -- Reset progress
  vim.keymap.set('n', 'r', function() M.reset() end, opts)
  
  -- Helper to apply indentation from target line
  apply_indent = function(row)
    local target = state.target_lines[row + 1] or ""
    local indent = target:match("^(%s*)") or ""
    if indent ~= "" then
       -- Only set if the line is currently empty or just has less whitespace
       local current = api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1] or ""
       if current == "" then
          api.nvim_buf_set_lines(state.buf, row, row + 1, false, { indent })
       end
    end
    return #indent
  end

  local function set_line(row_0, text)
    api.nvim_buf_set_lines(state.buf, row_0, row_0 + 1, false, { text })
    render_line(row_0, text)
  end

  local function clear_line(row_0, enter_insert)
    local target = state.target_lines[row_0 + 1] or ""
    local indent = target:match("^(%s*)") or ""
    set_line(row_0, indent)
    api.nvim_win_set_cursor(state.win, { row_0 + 1, #indent })
    if enter_insert then vim.cmd('startinsert') end
  end

  local function paste_overwrite(after)
    local cur = api.nvim_win_get_cursor(state.win)
    local row_0, col = cur[1] - 1, cur[2]
    local reg = vim.v.register
    local regtype = vim.fn.getregtype(reg)
    local lines = vim.fn.getreg(reg, 1, true)
    if type(lines) == "string" then lines = { lines } end

    if regtype:sub(1, 1) == "V" then
      for i, line in ipairs(lines) do
        local r = row_0 + i - 1
        if r >= #state.target_lines then break end
        set_line(r, line)
      end
      api.nvim_win_set_cursor(state.win, { row_0 + 1, 0 })
      return
    end

    if #lines <= 1 then
      local line = api.nvim_buf_get_lines(state.buf, row_0, row_0 + 1, false)[1] or ""
      local insert_at = col + (after and 1 or 0)
      if insert_at < 0 then insert_at = 0 end
      if insert_at > #line then insert_at = #line end
      local new_line = line:sub(1, insert_at) .. lines[1] .. line:sub(insert_at + 1)
      set_line(row_0, new_line)
      api.nvim_win_set_cursor(state.win, { row_0 + 1, insert_at + #lines[1] })
      return
    end

    for i, line in ipairs(lines) do
      local r = row_0 + i - 1
      if r >= #state.target_lines then break end
      set_line(r, line)
    end
    local last_r = math.min(row_0 + #lines - 1, #state.target_lines - 1)
    local last_line = lines[math.min(#lines, #state.target_lines - row_0)] or ""
    api.nvim_win_set_cursor(state.win, { last_r + 1, #last_line })
  end

  -- Remap 'o' and 'O' to navigate instead of inserting lines
  vim.keymap.set('n', 'o', function()
    local cur = api.nvim_win_get_cursor(state.win)
    local r, c = get_next_vibe_pos(cur[1] - 1, 1) -- 0-based current row, direction down
    api.nvim_win_set_cursor(state.win, { r, c })
    vim.cmd('startinsert')
  end, opts)

  vim.keymap.set('n', 'O', function()
    local cur = api.nvim_win_get_cursor(state.win)
    local r, c = get_next_vibe_pos(cur[1] - 1, -1) -- 0-based current row, direction up
    api.nvim_win_set_cursor(state.win, { r, c })
    vim.cmd('startinsert')
  end, opts)
  
  -- Custom 'w' to navigate to next word in ghost text
  vim.keymap.set('n', 'w', function()
    local cur = api.nvim_win_get_cursor(state.win)
    local r, c = cur[1] - 1, cur[2] -- 0-based
    
    local line = state.target_lines[r + 1] or ""
    local len = #line
    
    -- 1. Scan past current word characters (non-space)
    while c < len do
       local char = line:sub(c + 1, c + 1)
       if char:match("%s") then break end
       c = c + 1
    end
    
    -- 2. Scan past whitespace
    while c < len do
       local char = line:sub(c + 1, c + 1)
       if not char:match("%s") then break end
       c = c + 1
    end
    
    -- 3. If at EOL, go to next line
    if c >= len then
       local next_r = r + 1
       if next_r < #state.target_lines then
          local next_line = state.target_lines[next_r + 1] or ""
          local next_c = 0
          -- Skip leading whitespace on next line
          while next_c < #next_line do
             if not next_line:sub(next_c + 1, next_c + 1):match("%s") then break end
             next_c = next_c + 1
          end
          api.nvim_win_set_cursor(state.win, { next_r + 1, next_c })
       end
    else
       api.nvim_win_set_cursor(state.win, { r + 1, c })
    end
  end, opts)
  
  -- Safe versions of line-editing/paste to preserve alignment
  vim.keymap.set('n', 'dd', function()
    local cur = api.nvim_win_get_cursor(state.win)
    clear_line(cur[1] - 1, false)
  end, opts)

  vim.keymap.set('n', 'cc', function()
    local cur = api.nvim_win_get_cursor(state.win)
    clear_line(cur[1] - 1, true)
  end, opts)

  vim.keymap.set('n', 'S', function()
    local cur = api.nvim_win_get_cursor(state.win)
    clear_line(cur[1] - 1, true)
  end, opts)

  vim.keymap.set('n', 'p', function()
    paste_overwrite(true)
  end, opts)

  vim.keymap.set('n', 'P', function()
    paste_overwrite(false)
  end, opts)
  
  -- Handle Enter: Move to next line without inserting newline
  vim.keymap.set('i', '<CR>', function()
    local cur = api.nvim_win_get_cursor(state.win)
    local r, c = get_next_vibe_pos(cur[1] - 1, 1) -- 0-based current row, direction down
    api.nvim_win_set_cursor(state.win, { r, c })
  end, opts)
  
  -- Handle Backspace: Prevent joining lines (deleting newline at col 0)
  vim.keymap.set('i', '<BS>', function()
    local cur = api.nvim_win_get_cursor(state.win)
    if cur[2] == 0 then
      -- Prevent backspacing into previous line which causes line join
      return ""
    else
      return "<BS>"
    end
  end, { buffer = state.buf, expr = true, replace_keycodes = true })
  
  -- Start in insert mode
  vim.cmd('startinsert')
  
  -- Restore cursor if resuming
  if start_cursor then
     pcall(api.nvim_win_set_cursor, state.win, start_cursor)
  end
  
  start_timer()
  update_title(true) -- Initial update
  update_progress_line()
  
  -- Set up saving and cleanup
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = state.buf,
    callback = function()
      M.save()
    end,
  })
  
  api.nvim_create_autocmd("BufWipeout", {
    buffer = state.buf,
    callback = function()
      M.save()
      M.cleanup()
    end,
  })
  
  vim.bo[state.buf].modified = false
end

function M.save()
  if not state.orig_buf then return end
  if not state.buf or not api.nvim_buf_is_valid(state.buf) then return end
  local lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local cursor = { 1, 0 }
  if state.win and api.nvim_win_is_valid(state.win) then
    local ok, pos = pcall(api.nvim_win_get_cursor, state.win)
    if ok and pos then cursor = pos end
  end
  
  -- Calculate elapsed time to save
  if state.stats.active_start then
      local burst = vim.uv.now() - state.stats.active_start
      state.stats.accumulated_ms = state.stats.accumulated_ms + burst
      state.stats.active_start = vim.uv.now() -- Reset burst start
  end
  
  local elapsed = state.stats.accumulated_ms / 1000
  local buf_name = api.nvim_buf_get_name(state.orig_buf)
  
  progress_cache[buf_name] = {
     lines = lines,
     cursor = cursor,
     elapsed = elapsed,
  }
  persist_progress_cache()
  
  vim.bo[state.buf].modified = false
  vim.notify("VibeCheck progress saved!", vim.log.levels.INFO)
end

function M.cleanup()
  if state.stats.timer then
     state.stats.timer:stop()
     state.stats.timer:close()
     state.stats.timer = nil
  end
  state.win = nil
  state.buf = nil
  state.target_lines = {}
  state.hl_cache = {}
end

function M.close()
  if state.win and api.nvim_win_is_valid(state.win) then
    vim.cmd('q')
  end
end

function M.stats()
  load_progress_cache()

  local items = {}
  local name_width = 0
  local totals_width = 0
  local pct_width = 0
  local wpm_width = 0
  local acc_width = 0

  for buf_name, cached in pairs(progress_cache) do
    local target_lines = nil
    if buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 then
      local ok, lines = pcall(vim.fn.readfile, buf_name)
      if ok and type(lines) == "table" then target_lines = lines end
    end

    local total_lines = target_lines and #target_lines or #cached.lines
    if total_lines < 1 then total_lines = 1 end

    local cursor_line = 1
    if cached.cursor and cached.cursor[1] then
      cursor_line = cached.cursor[1]
    end
    if cursor_line < 1 then cursor_line = 1 end
    if cursor_line > total_lines then cursor_line = total_lines end

    local pct = math.floor((cursor_line / total_lines) * 100)
    local wpm, acc = "n/a", "n/a"
    if target_lines then
      local calc_wpm, calc_acc = compute_stats_for(target_lines, cached.lines or {}, cached.elapsed or 0)
      wpm = tostring(calc_wpm)
      acc = tostring(calc_acc)
    end

    local name = (buf_name ~= "" and buf_name) or "[No Name]"
    local name_label = vim.fn.fnamemodify(name, ":~")
    name_width = math.max(name_width, #name_label)
    totals_width = math.max(totals_width, #(tostring(cursor_line) .. "/" .. tostring(total_lines)))
    pct_width = math.max(pct_width, #tostring(pct))
    wpm_width = math.max(wpm_width, #tostring(wpm))
    acc_width = math.max(acc_width, #tostring(acc))

    table.insert(items, {
      name = name_label,
      cursor_line = cursor_line,
      total_lines = total_lines,
      pct = pct,
      wpm = wpm,
      acc = acc,
    })
  end

  table.sort(items, function(a, b) return a.name < b.name end)

  if #items == 0 then
    vim.notify("VibeCheck: no saved sessions.", vim.log.levels.INFO)
    return
  end

  local manual_total_chars = 0
  local manual_correct_chars = 0
  local manual_files = api.nvim_get_runtime_file("doc/*.txt", true) or {}
  for _, path in ipairs(manual_files) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok and type(lines) == "table" then
      for _, line in ipairs(lines) do
        manual_total_chars = manual_total_chars + #line
      end
      local cached = progress_cache[path]
      if cached and cached.lines then
        local correct, _ = compute_correct_typed(lines, cached.lines)
        manual_correct_chars = manual_correct_chars + correct
      end
    end
  end

  local manual_pct = 0
  if manual_total_chars > 0 then
    manual_pct = math.floor((manual_correct_chars / manual_total_chars) * 100)
  end

  local manual_line = string.format(
    " Neovim manual progress: %d%% (%d/%d chars) ",
    manual_pct,
    manual_correct_chars,
    manual_total_chars
  )

  local lines = { " VibeCheck Stats ", manual_line, "" }
  for _, item in ipairs(items) do
    local totals = string.format("%d/%d", item.cursor_line, item.total_lines)
    local line = string.format(
      "%-" .. name_width .. "s  %" .. totals_width .. "s  (%" .. pct_width .. "s%%)  WPM: %" .. wpm_width .. "s  Acc: %" .. acc_width .. "s%%",
      item.name,
      totals,
      tostring(item.pct),
      tostring(item.wpm),
      tostring(item.acc)
    )
    table.insert(lines, line)
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "filetype", "vibecheckstats")

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.9))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " VibeCheck Stats ",
    title_pos = "center",
  })

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", ":q<CR>", { buffer = buf, noremap = true, silent = true })
end

return M
