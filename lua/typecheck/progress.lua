local M = {}

local function join_lines(lines)
	if not lines or #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n")
end

local function get_hunks(old_lines, new_lines)
	if not (vim and vim.text and vim.text.diff) then
		return nil
	end
	local ok, hunks = pcall(vim.text.diff, join_lines(old_lines), join_lines(new_lines), {
		result_type = "indices",
	})
	if not ok or type(hunks) ~= "table" then
		return nil
	end
	return hunks
end

local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	end
	if value > max_value then
		return max_value
	end
	return value
end

function M.remap_progress(old_target, new_target, old_typed, old_cursor)
	if type(old_target) ~= "table" or type(new_target) ~= "table" then
		return nil
	end

	old_typed = old_typed or {}
	old_cursor = old_cursor or { 1, 0 }

	local hunks = get_hunks(old_target, new_target)
	if not hunks then
		return nil
	end

	local new_typed = {}
	for i = 1, #new_target do
		new_typed[i] = ""
	end

	local old_i, new_i = 1, 1
	local cursor = {
		line = old_cursor[1] or 1,
		col = old_cursor[2] or 0,
		new_line = nil,
		new_col = 0,
	}
	local preserved = 0

	local function map_unchanged(count)
		if count <= 0 then
			return
		end
		for offset = 0, count - 1 do
			local oi = old_i + offset
			local ni = new_i + offset
			new_typed[ni] = old_typed[oi] or ""
			preserved = preserved + 1
			if cursor.line == oi then
				cursor.new_line = ni
				cursor.new_col = clamp(cursor.col, 0, #(new_typed[ni] or ""))
			end
		end
		old_i = old_i + count
		new_i = new_i + count
	end

	for _, hunk in ipairs(hunks) do
		local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
		if not start_a or not start_b then
			goto continue
		end

		local old_end = (count_a == 0) and start_a or (start_a - 1)
		local new_end = (count_b == 0) and start_b or (start_b - 1)
		old_end = math.max(old_end or 0, old_i - 1)
		new_end = math.max(new_end or 0, new_i - 1)

		local unchanged_old = old_end - old_i + 1
		local unchanged_new = new_end - new_i + 1
		local unchanged = math.min(unchanged_old, unchanged_new)
		if unchanged > 0 then
			map_unchanged(unchanged)
		end

		local old_change_start = old_end + 1
		local new_change_start = new_end + 1

		if count_a > 0 then
			local old_change_end = old_change_start + count_a - 1
			if cursor.line >= old_change_start and cursor.line <= old_change_end then
				local target_line = new_change_start
				if target_line < 1 then
					target_line = 1
				end
				if target_line > #new_target then
					target_line = #new_target
				end
				cursor.new_line = target_line
				cursor.new_col = 0
			end
		end

		old_i = old_change_start + count_a
		new_i = new_change_start + count_b
		::continue::
	end

	local remaining_old = #old_target - old_i + 1
	local remaining_new = #new_target - new_i + 1
	local remaining = math.min(remaining_old, remaining_new)
	if remaining > 0 then
		map_unchanged(remaining)
	end

	local new_cursor_line = cursor.new_line or clamp(cursor.line, 1, math.max(#new_target, 1))
	local new_cursor_col = clamp(cursor.new_col or 0, 0, #(new_typed[new_cursor_line] or ""))

	return {
		lines = new_typed,
		cursor = { new_cursor_line, new_cursor_col },
		preserved = preserved,
		total = #new_target,
	}
end

return M
