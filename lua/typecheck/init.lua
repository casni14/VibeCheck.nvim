local M = {}
local api = vim.api
local apply_indent
local progress = require("typecheck.progress")

-- Cache for resuming sessions
-- [buf_name] = { lines = {}, cursor = {}, elapsed = 0 }
local progress_cache = {}
local progress_cache_path = vim.fn.stdpath("state") .. "/typecheck_progress.json"
local session_history = {}

local default_config = {
	auto_skip_separators = true,
	history_size = 200,
	daily_goal_minutes = 30,
	auto_indent = true,
}

local state

local function load_progress_cache()
	if vim.fn.filereadable(progress_cache_path) ~= 1 then
		return
	end
	local ok, lines = pcall(vim.fn.readfile, progress_cache_path)
	if not ok or not lines or #lines == 0 then
		return
	end
	local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if decoded_ok and type(decoded) == "table" then
		if decoded.progress and type(decoded.progress) == "table" then
			progress_cache = decoded.progress
			session_history = decoded.history or {}
		else
			progress_cache = decoded
			session_history = {}
		end
	end
end

local function disable_completions_for(bufnr)
	vim.b[bufnr].minicompletion_disable = true
	vim.b[bufnr].copilot_enabled = false
	vim.b[bufnr].cmp_enabled = false
	vim.b[bufnr].blink_cmp_disable = true
	vim.b[bufnr].coc_suggest_disable = 1
	vim.b[bufnr].supermaven_disable = true
	vim.b[bufnr].codeium_disable = true
	vim.b[bufnr].neocodeium_disable = true
	vim.b[bufnr].tabnine_disable = true
	vim.b[bufnr].completion = false -- blink.cmp uses this to disable

	vim.bo[bufnr].omnifunc = ""
	vim.bo[bufnr].completefunc = ""
	vim.bo[bufnr].complete = ""

	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp then
		cmp.setup.buffer({ enabled = false, sources = {} })
		if type(cmp.visible) == "function" and cmp.visible() then
			cmp.abort()
		end
	end

	local ok_blink, blink = pcall(require, "blink.cmp")
	if ok_blink and blink.hide then
		blink.hide()
	end
end

local function install_backspace_maps(bufnr)
	local function handle_backspace()
		if not state.win or not api.nvim_win_is_valid(state.win) then
			local keys = api.nvim_replace_termcodes("<BS>", true, false, true)
			api.nvim_feedkeys(keys, "n", false)
			return
		end

		local cur = api.nvim_win_get_cursor(state.win)
		local target = state.target_lines[cur[1]] or ""
		local indent = target:match("^(%s*)") or ""
		if cur[2] <= #indent then
			-- Move to previous line instead of joining lines
			local prev_row = cur[1] - 2 -- 0-based
			if prev_row >= 0 then
				local line = api.nvim_buf_get_lines(state.buf, prev_row, prev_row + 1, false)[1] or ""
				if line == "" then
					local prev_indent = apply_indent(prev_row)
					line = api.nvim_buf_get_lines(state.buf, prev_row, prev_row + 1, false)[1] or ""
					api.nvim_win_set_cursor(state.win, { prev_row + 1, math.max(#line, prev_indent) })
				else
					api.nvim_win_set_cursor(state.win, { prev_row + 1, #line })
				end
			end
			return
		end

		local keys = api.nvim_replace_termcodes("<BS>", true, false, true)
		api.nvim_feedkeys(keys, "n", false)
	end

	local map_opts = { buffer = bufnr, noremap = true, silent = true }
	vim.keymap.set("i", "<BS>", handle_backspace, map_opts)
	vim.keymap.set("i", "<C-h>", handle_backspace, map_opts)
	vim.keymap.set("i", "<Del>", handle_backspace, map_opts)
end

local function persist_progress_cache()
	local payload = {
		progress = progress_cache,
		history = session_history,
	}
	local ok, encoded = pcall(vim.json.encode, payload)
	if not ok or not encoded then
		return
	end
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
	if total_ms < 1000 then
		total_ms = 1000
	end
	local mins = total_ms / 60000
	local wpm = math.floor((total_correct / 5) / mins)

	local acc = 100
	if total_typed > 0 then
		acc = math.floor((total_correct / total_typed) * 100)
	end

	return wpm, acc
end

local function compute_elapsed_s()
	if not state or not state.stats then
		return 0
	end
	local elapsed_ms = state.stats.accumulated_ms or 0
	if state.stats.active_start then
		elapsed_ms = elapsed_ms + (vim.uv.now() - state.stats.active_start)
	end
	if elapsed_ms < 0 then
		elapsed_ms = 0
	end
	return elapsed_ms / 1000
end

-- State
state = {
	buf = nil,
	win = nil,
	orig_buf = nil,
	orig_win = nil,
	target_lines = {},
	hl_cache = {},
	ns = api.nvim_create_namespace("TypeCheck"),
	progress_ns = api.nvim_create_namespace("TypeCheckProgress"),
	stats = {
		accumulated_ms = 0,
		active_start = nil, -- nil means paused
		last_type = nil,
		line_counts = {}, -- [row] = count
		timer = nil,
		start_elapsed_s = 0,
		session_started_at = nil,
	},
	progress_mark_id = nil,
	config = vim.deepcopy(default_config),
	session_recorded = false,
	suppress_on_lines = false,
	pending_indent_fix = {},
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

	set_hl("TypeCheckDim", { link = "Comment" })
	set_hl("TypeCheckCorrect", { link = "String" }) -- Fallback
	set_hl("TypeCheckWrong", { link = "Error" })
	set_hl("TypeCheckCursor", { bg = "#555555", fg = "#ffffff" })
end

-- Helper to check if a line is a separator (repeating punctuation/symbols)
local function is_separator_line(line_idx_0based)
	if line_idx_0based >= #state.target_lines or line_idx_0based < 0 then
		return false
	end
	local line_text = state.target_lines[line_idx_0based + 1] or ""
	local stripped_line = line_text:gsub("%s", "") -- Remove whitespace for check

	if #stripped_line == 0 then
		return false
	end -- Empty line is not a separator
	if #stripped_line < 5 then
		return false
	end -- Too short to be a meaningful separator

	local first_char = stripped_line:sub(1, 1)
	-- If the first character is alphanumeric, it's probably code, not a separator
	if first_char:match("[%%a%%d]") then
		return false
	end -- Lua patterns: %a for alphabetic, %d for digit

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
	if not state.orig_buf then
		return "TypeCheckCorrect"
	end

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

	return "TypeCheckCorrect"
end

local function get_cached_hl(row, col)
	if not state.hl_cache[row] then
		state.hl_cache[row] = {}
	end
	if not state.hl_cache[row][col] then
		state.hl_cache[row][col] = get_origin_hl(row, col)
	end
	return state.hl_cache[row][col]
end

local function in_insert_mode()
	local mode = api.nvim_get_mode().mode
	return mode and mode:sub(1, 1) == "i"
end

-- Logic to calculate diff and render
local function render_line(row, user_line)
	if not state.target_lines then
		return
	end
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
			table.insert(chunks, { display, "TypeCheckWrong" })
		elseif u_char == t_char then
			correct_chars = correct_chars + 1
			local hl = get_cached_hl(row, i - 1)
			table.insert(chunks, { u_char, hl })
		else
			-- Show what user typed in Red.
			local display = (u_char == " ") and "_" or u_char
			table.insert(chunks, { display, "TypeCheckWrong" })
		end
	end

	-- Remaining target text
	if #target_line > #user_line then
		local remaining = target_line:sub(#user_line + 1)
		table.insert(chunks, { remaining, "TypeCheckDim" })
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

local function apply_indent_fix(buf, row, target_indent)
	if not state or buf ~= state.buf or not api.nvim_buf_is_valid(buf) then
		state.pending_indent_fix[row] = nil
		return
	end

	local current = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	local current_leading = current:match("^(%s*)") or ""
	if current_leading == target_indent then
		state.pending_indent_fix[row] = nil
		return
	end

	local stripped = current:gsub("^%s*", "")
	local normalized = target_indent .. stripped

	if normalized ~= current then
		state.suppress_on_lines = true
		api.nvim_buf_set_lines(buf, row, row + 1, false, { normalized })
		state.suppress_on_lines = false
		render_line(row, normalized)
	else
		render_line(row, current)
	end

	if state.win and api.nvim_win_is_valid(state.win) then
		local cur = api.nvim_win_get_cursor(state.win)
		if cur[1] == row + 1 then
			local delta = #target_indent - #current_leading
			local new_col = cur[2] + delta
			if new_col < 0 then
				new_col = 0
			end
			api.nvim_win_set_cursor(state.win, { row + 1, new_col })
		end
	end

	state.pending_indent_fix[row] = nil
end

local function queue_indent_fix(buf, row, target_indent)
	state.pending_indent_fix[row] = target_indent
	vim.schedule(function()
		local indent = state.pending_indent_fix[row]
		if indent == nil then
			return
		end
		apply_indent_fix(buf, row, indent)
	end)
end

local function on_lines(_, buf, _, firstline, _, new_lastline, _)
	if buf ~= state.buf then
		return
	end
	if state.suppress_on_lines then
		return
	end

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
		local lines = api.nvim_buf_get_lines(buf, i, i + 1, false)
		local line = (lines[1] or "")
		local target = state.target_lines[i + 1] or ""
		local target_indent = target:match("^(%s*)") or ""
		local leading = line:match("^(%s*)") or ""

		if state.config.auto_indent and leading ~= target_indent then
			local stripped = line:gsub("^%s*", "")
			local normalized = target_indent .. stripped
			if normalized ~= line then
				queue_indent_fix(buf, i, target_indent)
				line = normalized
			end
		end

		render_line(i, line)
	end
end

local function update_title(status)
	if not state.win or not api.nvim_win_is_valid(state.win) then
		return
	end

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
	if total_ms < 1000 then
		total_ms = 1000
	end

	local mins = total_ms / 60000
	local wpm = math.floor((total_correct / 5) / mins)

	local acc = 100
	if total_typed > 0 then
		acc = math.floor((total_correct / total_typed) * 100)
	end

	local label = status or "WPM"
	local title = string.format(" TypeCheck (%s: %d | Acc: %d%%) ", label, wpm, acc)
	api.nvim_win_set_config(state.win, { title = title })
end

local function update_progress_line()
	if state.win and api.nvim_win_is_valid(state.win) then
		local total = #state.target_lines
		if total == 0 then
			return
		end

		local cur = 1
		local pos = api.nvim_win_get_cursor(state.win)
		if pos and pos[1] then
			cur = pos[1]
		end

		local pct = math.floor((cur / total) * 100)
		local text = string.format(" Progress: %d/%d (%d%%) ", cur, total, pct)
		local winbar = text:gsub("%%", "%%%%")
		api.nvim_win_set_option(state.win, "winbar", winbar)
	end
end

local function check_timer()
	if not state.win or not api.nvim_win_is_valid(state.win) then
		return
	end

	local now = vim.uv.now()

	-- Check pause condition
	if state.stats.active_start then
		if state.stats.last_type and (now - state.stats.last_type) > 2000 then -- 2 seconds timeout
			-- Pause
			local burst = state.stats.last_type - state.stats.active_start
			state.stats.accumulated_ms = state.stats.accumulated_ms + burst
			state.stats.active_start = nil
		end
	end

	local status = "PAUSED"
	if state.stats.active_start then
		status = "WPM"
	end
	update_title(status)
	update_progress_line()
end

local function start_timer()
	state.stats.timer = vim.uv.new_timer()
	state.stats.timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			if state.win and api.nvim_win_is_valid(state.win) then
				check_timer()
			else
				if state.stats.timer then
					state.stats.timer:stop()
					state.stats.timer:close()
					state.stats.timer = nil
				end
			end
		end)
	)
end

load_progress_cache()

function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", default_config, opts or {})
end

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
	api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(state.buf, "buftype", "acwrite")
	api.nvim_buf_set_name(state.buf, "TypeCheck")
	api.nvim_buf_set_option(state.buf, "filetype", "typecheck")

	-- Disable distractions (Autocompletion, Diagnostics, AI)
	if vim.diagnostic.enable then
		vim.diagnostic.enable(false, { bufnr = state.buf })
	else
		vim.diagnostic.disable(state.buf)
	end
	disable_completions_for(state.buf)
	-- Note: blink.cmp usually respects 'filetype' exclusion or lack of LSP sources

	-- Keep disabling after lazy-loading completion engines.
	api.nvim_create_autocmd({ "BufEnter", "InsertEnter", "TextChangedI", "CompleteChanged" }, {
		buffer = state.buf,
		callback = function()
			disable_completions_for(state.buf)
			install_backspace_maps(state.buf)
			if vim.fn.pumvisible() == 1 then
				local keys = api.nvim_replace_termcodes("<C-e>", true, false, true)
				api.nvim_feedkeys(keys, "n", false)
			end
		end,
	})

	-- Check cache for resume
	local buf_name = api.nvim_buf_get_name(current_buf)
	local cached = progress_cache[buf_name]
	local start_lines = {}
	local start_cursor = { 1, 0 }
	local start_elapsed = 0

	if cached then
		start_elapsed = cached.elapsed or 0

		local remapped = nil
		if cached.target and type(cached.target) == "table" and cached.lines and #cached.target == #cached.lines then
			remapped = progress.remap_progress(cached.target, lines, cached.lines, cached.cursor)
		end

		if remapped and remapped.lines then
			start_lines = remapped.lines
			if remapped.cursor then
				start_cursor = remapped.cursor
			end
		elseif cached.lines and #cached.lines == #lines then
			start_lines = cached.lines
			if cached.cursor then
				start_cursor = cached.cursor
			end
		end
	end

	if #start_lines == 0 then
		for _ = 1, #lines do
			table.insert(start_lines, "")
		end
		-- Ensure at least one line (already handled by loop if #lines > 0)
		if #start_lines == 0 then
			table.insert(start_lines, "")
		end
	end

	if start_cursor[1] < 1 then
		start_cursor[1] = 1
	end
	if start_cursor[1] > #start_lines then
		start_cursor[1] = #start_lines
	end

	local line_at_cursor = start_lines[start_cursor[1]] or ""
	if start_cursor[2] < #line_at_cursor then
		start_cursor = { start_cursor[1], start_cursor[2] + 1 }
	end

	-- Init Stats
	state.stats = {
		accumulated_ms = start_elapsed * 1000,
		active_start = nil, -- Starts paused
		last_type = nil,
		line_counts = {},
		timer = nil,
		start_elapsed_s = start_elapsed,
		session_started_at = os.time(),
	}
	state.session_recorded = false

	api.nvim_buf_set_lines(state.buf, 0, -1, false, start_lines)

	-- 3. Create floating window
	local width = api.nvim_get_option("columns")
	local height = api.nvim_get_option("lines")

	state.win = api.nvim_open_win(state.buf, true, {
		relative = "editor",
		width = width - 4,
		height = height - 4,
		col = 2,
		row = 0,
		style = "minimal",
		border = "rounded",
		title = " TypeCheck ",
		title_pos = "center",
	})

	-- Allow navigation into ghost text
	vim.wo[state.win].virtualedit = "all"

	-- Sync line numbers with original window
	if state.orig_win and api.nvim_win_is_valid(state.orig_win) then
		api.nvim_win_set_option(state.win, "number", api.nvim_win_get_option(state.orig_win, "number"))
		api.nvim_win_set_option(state.win, "relativenumber", api.nvim_win_get_option(state.orig_win, "relativenumber"))
	end

	-- 4. Initial Render
	for i = 0, #lines - 1 do
		render_line(i, start_lines[i + 1] or "")
	end

	-- 5. Attach listener
	api.nvim_buf_attach(state.buf, false, {
		on_lines = on_lines,
	})

	-- 6. Keymaps
	local opts = { noremap = true, silent = true, buffer = state.buf }

	-- Use 'q' to quit from Normal mode
	vim.keymap.set("n", "q", ":q<CR>", opts)

	-- Reset progress
	vim.keymap.set("n", "r", function()
		M.reset()
	end, opts)

	-- Helper to apply indentation from target line
	apply_indent = function(row)
		local current = api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1] or ""
		local current_indent = current:match("^(%s*)") or ""
		if not state.config.auto_indent then
			return #current_indent
		end

		local target = state.target_lines[row + 1] or ""
		local indent = target:match("^(%s*)") or ""
		if indent ~= "" then
			-- Only set if the line is currently empty or just has less whitespace
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
		local indent = ""
		if state.config.auto_indent then
			local target = state.target_lines[row_0 + 1] or ""
			indent = target:match("^(%s*)") or ""
		end
		set_line(row_0, indent)
		api.nvim_win_set_cursor(state.win, { row_0 + 1, #indent })
		if enter_insert then
			vim.cmd("startinsert")
		end
	end

	local function paste_overwrite(after)
		local cur = api.nvim_win_get_cursor(state.win)
		local row_0, col = cur[1] - 1, cur[2]
		local reg = vim.v.register
		local regtype = vim.fn.getregtype(reg)
		local lines = vim.fn.getreg(reg, 1, true)
		if type(lines) == "string" then
			lines = { lines }
		end

		if regtype:sub(1, 1) == "V" then
			for i, line in ipairs(lines) do
				local r = row_0 + i - 1
				if r >= #state.target_lines then
					break
				end
				set_line(r, line)
			end
			api.nvim_win_set_cursor(state.win, { row_0 + 1, 0 })
			return
		end

		if #lines <= 1 then
			local line = api.nvim_buf_get_lines(state.buf, row_0, row_0 + 1, false)[1] or ""
			local insert_at = col + (after and 1 or 0)
			if insert_at < 0 then
				insert_at = 0
			end
			if insert_at > #line then
				insert_at = #line
			end
			local new_line = line:sub(1, insert_at) .. lines[1] .. line:sub(insert_at + 1)
			set_line(row_0, new_line)
			api.nvim_win_set_cursor(state.win, { row_0 + 1, insert_at + #lines[1] })
			return
		end

		for i, line in ipairs(lines) do
			local r = row_0 + i - 1
			if r >= #state.target_lines then
				break
			end
			set_line(r, line)
		end
		local last_r = math.min(row_0 + #lines - 1, #state.target_lines - 1)
		local last_line = lines[math.min(#lines, #state.target_lines - row_0)] or ""
		api.nvim_win_set_cursor(state.win, { last_r + 1, #last_line })
	end

	-- Remap 'o' and 'O' to navigate instead of inserting lines
	vim.keymap.set("n", "o", function()
		local cur = api.nvim_win_get_cursor(state.win)
		local r, c = get_next_vibe_pos(cur[1] - 1, 1) -- 0-based current row, direction down
		api.nvim_win_set_cursor(state.win, { r, c })
		vim.cmd("startinsert")
	end, opts)

	vim.keymap.set("n", "O", function()
		local cur = api.nvim_win_get_cursor(state.win)
		local r, c = get_next_vibe_pos(cur[1] - 1, -1) -- 0-based current row, direction up
		api.nvim_win_set_cursor(state.win, { r, c })
		vim.cmd("startinsert")
	end, opts)

	-- Custom 'w' to navigate to next word in ghost text
	vim.keymap.set("n", "w", function()
		local cur = api.nvim_win_get_cursor(state.win)
		local r, c = cur[1] - 1, cur[2] -- 0-based

		local line = state.target_lines[r + 1] or ""
		local len = #line

		-- 1. Scan past current word characters (non-space)
		while c < len do
			local char = line:sub(c + 1, c + 1)
			if char:match("%s") then
				break
			end
			c = c + 1
		end

		-- 2. Scan past whitespace
		while c < len do
			local char = line:sub(c + 1, c + 1)
			if not char:match("%s") then
				break
			end
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
					if not next_line:sub(next_c + 1, next_c + 1):match("%s") then
						break
					end
					next_c = next_c + 1
				end
				api.nvim_win_set_cursor(state.win, { next_r + 1, next_c })
			end
		else
			api.nvim_win_set_cursor(state.win, { r + 1, c })
		end
	end, opts)

	-- Safe versions of line-editing/paste to preserve alignment
	vim.keymap.set("n", "dd", function()
		local cur = api.nvim_win_get_cursor(state.win)
		clear_line(cur[1] - 1, false)
	end, opts)

	vim.keymap.set("n", "cc", function()
		local cur = api.nvim_win_get_cursor(state.win)
		clear_line(cur[1] - 1, true)
	end, opts)

	vim.keymap.set("n", "S", function()
		local cur = api.nvim_win_get_cursor(state.win)
		clear_line(cur[1] - 1, true)
	end, opts)

	vim.keymap.set("n", "p", function()
		paste_overwrite(true)
	end, opts)

	vim.keymap.set("n", "P", function()
		paste_overwrite(false)
	end, opts)

	-- Handle Enter: Move to next line without inserting newline
	vim.keymap.set("i", "<CR>", function()
		local cur = api.nvim_win_get_cursor(state.win)
		local r, c = get_next_vibe_pos(cur[1] - 1, 1) -- 0-based current row, direction down
		api.nvim_win_set_cursor(state.win, { r, c })
	end, opts)

	install_backspace_maps(state.buf)

	-- Start in insert mode
	vim.cmd("startinsert")

	-- Restore cursor if resuming
	if start_cursor then
		pcall(api.nvim_win_set_cursor, state.win, start_cursor)
	end

	start_timer()
	update_title("PAUSED") -- Initial update
	update_progress_line()

	-- Set up saving and cleanup
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = state.buf,
		callback = function()
			M.save({ notify = true })
		end,
	})

	api.nvim_create_autocmd("BufWipeout", {
		buffer = state.buf,
		callback = function()
			M.record_session()
			M.save({ notify = false })
			M.cleanup()
		end,
	})

	vim.bo[state.buf].modified = false
end

function M.save(opts)
	opts = opts or {}
	local notify = opts.notify ~= false
	if not state.orig_buf then
		return
	end
	if not state.buf or not api.nvim_buf_is_valid(state.buf) then
		return
	end
	local lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
	local cursor = { 1, 0 }
	if state.win and api.nvim_win_is_valid(state.win) then
		local ok, pos = pcall(api.nvim_win_get_cursor, state.win)
		if ok and pos then
			cursor = pos
		end
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
		target = state.target_lines,
	}
	persist_progress_cache()

	vim.bo[state.buf].modified = false
	if notify then
		vim.notify("TypeCheck progress saved!", vim.log.levels.INFO)
	end
end

function M.record_session()
	if state.session_recorded then
		return
	end
	if not state.orig_buf or not state.buf or not api.nvim_buf_is_valid(state.buf) then
		return
	end
	if not state.target_lines or #state.target_lines == 0 then
		return
	end

	local lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
	local elapsed_s = compute_elapsed_s()
	local base_elapsed_s = state.stats.start_elapsed_s or 0
	local session_elapsed_s = elapsed_s - base_elapsed_s
	if session_elapsed_s < 0 then
		session_elapsed_s = 0
	end
	local wpm, acc = compute_stats_for(state.target_lines, lines, elapsed_s)
	local correct, typed = compute_correct_typed(state.target_lines, lines)

	local entry = {
		ts = os.time(),
		wpm = wpm,
		acc = acc,
		correct = correct,
		typed = typed,
		elapsed = elapsed_s,
		session_elapsed = session_elapsed_s,
		file = api.nvim_buf_get_name(state.orig_buf),
	}
	table.insert(session_history, entry)
	local limit = state.config.history_size or default_config.history_size
	if limit and #session_history > limit then
		table.remove(session_history, 1)
	end

	state.session_recorded = true
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
		vim.cmd("q")
	end
end

function M.stats()
	load_progress_cache()

	local function display_width(text)
		return vim.fn.strdisplaywidth(text)
	end

	local function set_stats_highlights()
		api.nvim_set_hl(0, "TypeCheckStatsTitle", { link = "Title" })
		api.nvim_set_hl(0, "TypeCheckStatsDivider", { link = "Comment" })
		api.nvim_set_hl(0, "TypeCheckStatsSection", { link = "Function" })
		api.nvim_set_hl(0, "TypeCheckStatsLabel", { link = "Identifier" })
		api.nvim_set_hl(0, "TypeCheckStatsValue", { link = "Number" })
		api.nvim_set_hl(0, "TypeCheckStatsMuted", { link = "Comment" })
		api.nvim_set_hl(0, "TypeCheckStatsFile", { link = "Directory" })
		api.nvim_set_hl(0, "TypeCheckStatsProgress", { link = "Statement" })
		api.nvim_set_hl(0, "TypeCheckStatsBarFill", { link = "DiffAdd" })
		api.nvim_set_hl(0, "TypeCheckStatsBarEmpty", { link = "Comment" })
		api.nvim_set_hl(0, "TypeCheckStatsAchieved", { link = "DiagnosticOk" })
		api.nvim_set_hl(0, "TypeCheckStatsUnachieved", { link = "Comment" })
	end

	local function use_nerd_icons()
		if vim.g.have_nerd_font == true or vim.g.nerd_font == true then
			return true
		end
		local guifont = vim.o.guifont or ""
		return guifont:lower():match("nerd") ~= nil
	end

	local nerd = use_nerd_icons()
	local icons = {
		overview = nerd and "󰋯 " or "",
		manual = nerd and "󰈙 " or "",
		achievements = nerd and "󰄬 " or "",
		files = nerd and "󰈔 " or "",
		sessions = nerd and "󰔟 " or "",
		time = nerd and "󰅒 " or "",
		today = nerd and "󰔠 " or "",
		wpm = nerd and "󰓢 " or "",
		acc = nerd and "󰓛 " or "",
		trend = nerd and "󱎔 " or "",
	}
	local separators = {
		divider = nerd and "═" or "=",
		header = nerd and "─" or "-",
	}

	local items = {}
	local name_width = 0
	local totals_width = 0
	local pct_width = 0
	local wpm_width = 0
	local acc_width = 0
	local max_wpm = 0
	local max_acc = 0
	local any_complete = false
	local total_sessions = 0
	local total_elapsed_s = 0
	local avg_wpm = "n/a"
	local avg_acc = "n/a"
	local total_correct_chars = 0
	local total_typed_chars = 0

	for buf_name, cached in pairs(progress_cache) do
		total_sessions = total_sessions + 1
		total_elapsed_s = total_elapsed_s + (cached.elapsed or 0)
		local target_lines = nil
		if buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 then
			local ok, lines = pcall(vim.fn.readfile, buf_name)
			if ok and type(lines) == "table" then
				target_lines = lines
			end
		end

		local total_lines = target_lines and #target_lines or #cached.lines
		if total_lines < 1 then
			total_lines = 1
		end

		local cursor_line = 1
		if cached.cursor and cached.cursor[1] then
			cursor_line = cached.cursor[1]
		end
		if cursor_line < 1 then
			cursor_line = 1
		end
		if cursor_line > total_lines then
			cursor_line = total_lines
		end

		local pct = math.floor((cursor_line / total_lines) * 100)
		local wpm, acc = "n/a", "n/a"
		if target_lines then
			local calc_wpm, calc_acc = compute_stats_for(target_lines, cached.lines or {}, cached.elapsed or 0)
			wpm = tostring(calc_wpm)
			acc = tostring(calc_acc)
			if calc_wpm > max_wpm then
				max_wpm = calc_wpm
			end
			if calc_acc > max_acc then
				max_acc = calc_acc
			end
			local correct, typed = compute_correct_typed(target_lines, cached.lines or {})
			total_correct_chars = total_correct_chars + correct
			total_typed_chars = total_typed_chars + typed
		end
		if cursor_line >= total_lines then
			any_complete = true
		end

		local name = (buf_name ~= "" and buf_name) or "[No Name]"
		local name_label = vim.fn.fnamemodify(name, ":~")
		name_width = math.max(name_width, display_width(name_label))
		totals_width = math.max(totals_width, display_width(tostring(cursor_line) .. "/" .. tostring(total_lines)))
		pct_width = math.max(pct_width, display_width(tostring(pct)))
		wpm_width = math.max(wpm_width, display_width(tostring(wpm)))
		acc_width = math.max(acc_width, display_width(tostring(acc)))

		table.insert(items, {
			name = name_label,
			cursor_line = cursor_line,
			total_lines = total_lines,
			pct = pct,
			wpm = wpm,
			acc = acc,
		})
	end

	table.sort(items, function(a, b)
		return a.name < b.name
	end)

	if #items == 0 then
		vim.notify("TypeCheck: no saved sessions.", vim.log.levels.INFO)
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

	local function format_duration(seconds)
		local total = math.floor(seconds or 0)
		local mins = math.floor(total / 60)
		local secs = total % 60
		return string.format("%dm %ds", mins, secs)
	end

	local function format_wpm_trend(values)
		if not values or #values == 0 then
			return "n/a"
		end
		local levels = { " ", ".", ":", "-", "=", "+", "*", "#", "%", "@" }
		local min_v = values[1]
		local max_v = values[1]
		for i = 2, #values do
			if values[i] < min_v then
				min_v = values[i]
			end
			if values[i] > max_v then
				max_v = values[i]
			end
		end
		local span = max_v - min_v
		local out = {}
		for i = 1, #values do
			local idx = 1
			if span > 0 then
				local ratio = (values[i] - min_v) / span
				idx = math.floor(ratio * (#levels - 1)) + 1
			end
			out[i] = levels[idx]
		end
		return table.concat(out, "")
	end

	local function date_key(ts)
		return os.date("%Y-%m-%d", ts)
	end

	local function session_elapsed_for(entry, last_total_by_file)
		if entry and type(entry.session_elapsed) == "number" then
			return entry.session_elapsed
		end
		if not entry or type(entry.elapsed) ~= "number" then
			return 0
		end
		if entry.file then
			local prev = last_total_by_file[entry.file]
			if type(prev) == "number" then
				local delta = entry.elapsed - prev
				if delta >= 0 then
					return delta
				end
			end
		end
		return entry.elapsed
	end

	local function compute_daily_active_seconds(day_key)
		local total = 0
		local last_total_by_file = {}
		for _, entry in ipairs(session_history) do
			local entry_day = entry and entry.ts and date_key(entry.ts) or nil
			local session_elapsed = session_elapsed_for(entry, last_total_by_file)
			if entry_day == day_key and session_elapsed > 0 then
				total = total + session_elapsed
			end
			if entry and entry.file and type(entry.elapsed) == "number" then
				last_total_by_file[entry.file] = entry.elapsed
			end
		end
		return total
	end

	local function ach_line(label, ok)
		local mark = ok and "[x]" or "[ ]"
		return string.format(" %s %s", mark, label)
	end

	if total_elapsed_s > 0 and total_correct_chars > 0 then
		avg_wpm = tostring(math.floor((total_correct_chars / 5) / (total_elapsed_s / 60)))
	end
	if total_typed_chars > 0 then
		avg_acc = tostring(math.floor((total_correct_chars / total_typed_chars) * 100))
	end

	local recent_wpm = {}
	local history_count = #session_history
	local history_start = math.max(1, history_count - 19)
	for i = history_start, history_count do
		local entry = session_history[i]
		if entry and type(entry.wpm) == "number" then
			table.insert(recent_wpm, entry.wpm)
		end
	end
	local wpm_trend = format_wpm_trend(recent_wpm)

	local today_key = date_key(os.time())
	local active_today_s = compute_daily_active_seconds(today_key)
	if state.buf and api.nvim_buf_is_valid(state.buf) and state.stats and state.stats.session_started_at then
		if date_key(state.stats.session_started_at) == today_key then
			local current_elapsed = compute_elapsed_s() - (state.stats.start_elapsed_s or 0)
			if current_elapsed > 0 then
				active_today_s = active_today_s + current_elapsed
			end
		end
	end

	local daily_goal_min = tonumber(state.config.daily_goal_minutes or default_config.daily_goal_minutes) or 0
	if daily_goal_min < 0 then
		daily_goal_min = 0
	end
	local daily_goal_s = daily_goal_min * 60
	local daily_goal_line = ""
	local daily_goal_pct = 0
	if daily_goal_min > 0 then
		daily_goal_pct = math.floor((active_today_s / daily_goal_s) * 100)
		if daily_goal_pct < 0 then
			daily_goal_pct = 0
		end
		daily_goal_line = string.format(
			" Active today: %s (%d%% of %dm) ",
			format_duration(active_today_s),
			daily_goal_pct,
			daily_goal_min
		)
	else
		daily_goal_line = string.format(" Active today: %s (goal off) ", format_duration(active_today_s))
	end

	local summary = {
		string.format(" Total sessions: %d ", total_sessions),
		string.format(" Active time (all): %s ", format_duration(total_elapsed_s)),
		daily_goal_line,
		string.format(" Average WPM: %s ", avg_wpm),
		string.format(" Best WPM: %s ", max_wpm > 0 and tostring(max_wpm) or "n/a"),
		string.format(" Average accuracy: %s%% ", avg_acc),
		string.format(" Best accuracy: %s%% ", max_acc > 0 and tostring(max_acc) or "n/a"),
		string.format(" WPM trend (last %d): %s ", #recent_wpm, wpm_trend),
	}

	local achievements = {
		ach_line("First session saved", #items > 0),
		ach_line("Complete a file", any_complete),
		ach_line("Accuracy 90%+", max_acc >= 90),
		ach_line("Accuracy 100%", max_acc >= 100),
		ach_line("WPM 60+", max_wpm >= 60),
		ach_line("WPM 80+", max_wpm >= 80),
		ach_line("WPM 100+", max_wpm >= 100),
		ach_line("Manual progress 25%+", manual_pct >= 25),
		ach_line("Manual progress 50%+", manual_pct >= 50),
		ach_line("Manual progress 100%", manual_pct >= 100),
	}

	local function bar(pct, width)
		if pct < 0 then
			pct = 0
		end
		if pct > 100 then
			pct = 100
		end
		local filled = math.floor((pct / 100) * width)
		return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
	end

	local function format_progress(item)
		return string.format("%d/%d (%d%%)", item.cursor_line, item.total_lines, item.pct)
	end

	local progress_width = 0
	for _, item in ipairs(items) do
		progress_width = math.max(progress_width, display_width(format_progress(item)))
	end

	local bar_width = 12
	local goal_bar = ""
	if daily_goal_min > 0 then
		goal_bar = bar(daily_goal_pct, bar_width)
	end
	local divider_width = math.max(44, name_width + progress_width + bar_width + wpm_width + acc_width + 10)

	local manual_line_clean = manual_line:gsub("^%s*", "")
	local lines = {}
	local line_meta = {}
	local pad = "  "
	local function push(line, kind, meta)
		table.insert(lines, pad .. line)
		line_meta[#lines] = { kind = kind, meta = meta }
	end

	push("", "spacer")
	push(icons.overview .. "Overview", "section")
	push(string.format("%sSessions: %d", icons.sessions, total_sessions), "overview")
	push(string.format("%sActive time (all): %s", icons.time, format_duration(total_elapsed_s)), "overview")
	push(
		daily_goal_min > 0
				and string.format(
					"%sActive today: %s %s (%d%% of %dm)",
					icons.today,
					format_duration(active_today_s),
					goal_bar,
					daily_goal_pct,
					daily_goal_min
				)
			or string.format("%sActive today: %s (goal off)", icons.today, format_duration(active_today_s)),
		"overview"
	)
	push(
		string.format("%sAverage WPM: %s  Best WPM: %s", icons.wpm, avg_wpm, max_wpm > 0 and tostring(max_wpm) or "n/a"),
		"overview"
	)
	push(
		string.format(
			"%sAverage accuracy: %s%%  Best accuracy: %s%%",
			icons.acc,
			avg_acc,
			max_acc > 0 and tostring(max_acc) or "n/a"
		),
		"overview"
	)
	push(string.format("%sWPM trend (last %d): %s", icons.trend, #recent_wpm, wpm_trend), "overview")
	push("", "spacer")
	push(icons.manual .. "TTFManual", "section")
	push(manual_line_clean, "manual")
	push("", "spacer")
	push(icons.achievements .. "Achievements", "section")

	local cleaned_achievements = {}
	local ach_width = 0
	for _, line in ipairs(achievements) do
		local cleaned = line:gsub("^%s*", "")
		ach_width = math.max(ach_width, display_width(cleaned))
		table.insert(cleaned_achievements, cleaned)
	end

	for i = 1, #cleaned_achievements, 2 do
		local left = cleaned_achievements[i]
		local right = cleaned_achievements[i + 1]
		if right then
			local line = string.format("%-" .. ach_width .. "s  %s", left, right)
			push(line, "achievement")
		else
			push(left, "achievement")
		end
	end

	push("", "spacer")
	push(icons.files .. "Files", "section")

	local header = string.format(
		"%-"
			.. name_width
			.. "s  %-"
			.. progress_width
			.. "s  %-"
			.. (bar_width + 2)
			.. "s  %"
			.. wpm_width
			.. "s  %"
			.. acc_width
			.. "s",
		"File",
		"Progress",
		"Bar",
		"WPM",
		"Acc"
	)
	push(header, "files_header")
	push(string.rep(separators.header, display_width(header)), "files_divider")

	for _, item in ipairs(items) do
		local line = string.format(
			"%-"
				.. name_width
				.. "s  %-"
				.. progress_width
				.. "s  %-"
				.. (bar_width + 2)
				.. "s  %"
				.. wpm_width
				.. "s  %"
				.. acc_width
				.. "s",
			item.name,
			format_progress(item),
			bar(item.pct, bar_width),
			tostring(item.wpm),
			tostring(item.acc)
		)
		push(line, "file_row", { pct = item.pct })
	end

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(buf, "filetype", "typecheckstats")

	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, display_width(l))
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
		title = " TypeCheck Stats ",
		title_pos = "center",
	})

	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.keymap.set("n", "q", ":q<CR>", { buffer = buf, noremap = true, silent = true })

	set_stats_highlights()
	for idx, line in ipairs(lines) do
		local line_offset = 2
		local kind = line_meta[idx] and line_meta[idx].kind or nil
		local lnum = idx - 1
		if kind == "title" then
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsTitle", lnum, 0, -1)
		elseif kind == "divider" or kind == "files_divider" then
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsDivider", lnum, 0, -1)
		elseif kind == "section" then
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsSection", lnum, 0, -1)
		elseif kind == "overview" or kind == "manual" then
			local pos = line_offset
			while true do
				local colon = line:find(":", pos + 1, true)
				if not colon then
					break
				end
				api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsLabel", lnum, pos, colon)
				local value_start = colon + 2
				local next_sep = line:find("  ", value_start, true) or (#line + 1)
				api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsValue", lnum, value_start - 1, next_sep - 1)
				pos = next_sep
			end
		elseif kind == "achievement" then
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsMuted", lnum, line_offset, -1)
			local search_from = 1
			while true do
				local s, e = line:find("%[[x ]%]", search_from)
				if not s then
					break
				end
				local mark = line:sub(s, e)
				if mark == "[x]" then
					api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsAchieved", lnum, s - 1, e)
				else
					api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsUnachieved", lnum, s - 1, e)
				end
				search_from = e + 1
			end
		elseif kind == "files_header" then
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsSection", lnum, line_offset, -1)
		elseif kind == "file_row" then
			local col_file_start = line_offset
			local col_file_end = line_offset + name_width
			local col_progress_start = col_file_end + 2
			local col_progress_end = col_progress_start + progress_width
			local col_bar_start = col_progress_end + 2
			local col_bar_end = col_bar_start + bar_width + 2
			local col_wpm_start = col_bar_end + 2
			local col_wpm_end = col_wpm_start + wpm_width
			local col_acc_start = col_wpm_end + 2
			local col_acc_end = col_acc_start + acc_width

			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsFile", lnum, col_file_start, col_file_end)
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsProgress", lnum, col_progress_start, col_progress_end)

			local pct = line_meta[idx] and line_meta[idx].meta and line_meta[idx].meta.pct or 0
			local fill = math.floor((math.min(math.max(pct, 0), 100) / 100) * bar_width)
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsBarFill", lnum, col_bar_start, col_bar_start + 1 + fill)
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsBarEmpty", lnum, col_bar_start + 1 + fill, col_bar_end)

			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsValue", lnum, col_wpm_start, col_wpm_end)
			api.nvim_buf_add_highlight(buf, 0, "TypeCheckStatsValue", lnum, col_acc_start, col_acc_end)
		end
	end
end

return M
