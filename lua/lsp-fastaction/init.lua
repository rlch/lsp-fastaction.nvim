local window = require("lsp-fastaction.window")
local utils = require("lsp-fastaction.utils")

local api = vim.api
local state = {}
local M = {}
local key_used = {}
local namespace = api.nvim_create_namespace("windmenu")

local defaults_config = {
	action_data = {},
	hide_cursor = true,
	highlight = {
		window = "NormalFloat",
		divider = "FloatBorder",
		title = "Title",
		key = "MoreMsg",
	},
	action_title = "Code Actions:",
}

if _G.__is_dev then
	_G.__state = _G.__state or { config = defaults_config }
	state = _G.__state
end

M.setup = function(opts)
	state.config = vim.tbl_extend("force", defaults_config, opts)
end

local get_action_key = function(title, keys)
	local action_data = state.config.action_data[vim.bo.filetype] or {}
	for _, value in pairs(action_data) do
		if vim.tbl_contains(keys, value.key) == false and title:lower():match(value.pattern) then
			return value
		end
	end
end

local show_menu = function(responses)
	key_used = {}
	local action_tbl = {}
	if responses == nil or vim.tbl_isempty(responses) then
		print("No code actions available")
		return
	end

	table.sort(responses, function(a, b)
		return #a.title < #b.title
	end)
	local contents = {}
	local title = state.config.action_title

	local divider_char = "─"
	table.insert(contents, title)
	-- add a divider line
	table.insert(contents, 2, divider_char)

	-- get all action match with  code_action_data
	for _, resp in pairs(responses) do
		local match = get_action_key(resp.title, key_used)
		local action = {
			data = resp,
			order = 0,
		}
		if match then
			action.menu_key = match.key
			action.order = match.order
		else
			-- order by length
			action.order = #resp.title + 4
		end
		table.insert(key_used, action.menu_key)
		table.insert(action_tbl, action)
	end

	table.sort(action_tbl, function(a, b)
		return a.order < b.order
	end)
	for _, action in pairs(action_tbl) do
		if not action.menu_key then
			action.menu_key = utils.get_key(action.data.title, key_used)
			table.insert(key_used, action.menu_key)
		end
		table.insert(contents, string.format("[%s] %s", action.menu_key, action.data.title))
	end
	local win_width, win_height = vim.lsp.util._make_floating_popup_size(contents, {})
	--- replace divider placeholder with full width divider now we know the window width
	contents[2] = string.rep(divider_char, win_width)

	local bufnr, _ = window.popup_window(contents, "windmenu", {
		window = state.config.highlight.window,
		enter = true,
		border = true,
		height = win_height,
		width = win_width,
	})

	-- Add highlight for title
	api.nvim_buf_add_highlight(bufnr, namespace, state.config.highlight.title, 0, 0, -1)
	api.nvim_buf_add_highlight(bufnr, namespace, state.config.highlight.divider, 1, 0, -1)

	if state.config.hide_cursor then
		window.hide_cursor()
	end

	for _, action in pairs(action_tbl) do
		vim.api.nvim_buf_set_keymap(
			bufnr,
			"n",
			action.menu_key,
			string.format('<cmd>lua require("lsp-fastaction").do_action("%s")<cr>', action.menu_key),
			{ noremap = true }
		)
	end
	local line = 2 -- avoid the title and the divider i.e. start at line 2
	for _, _ in pairs(contents) do
		api.nvim_buf_add_highlight(bufnr, namespace, "MoreMsg", line, 0, 3)
		line = line + 1
	end

	vim.api.nvim_buf_set_keymap(bufnr, "n", "<esc>", ":q<cr>", { noremap = true, silent = true })
	state.action_tbl = action_tbl
end

local request_code_action = function(params)
	local results_lsp, err = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, 10000)
	if err then
		print("ERROR: " .. err)
		return
	end

	if not results_lsp or vim.tbl_isempty(results_lsp) then
		print("No results from textDocument/codeAction")
		return
	end
	local commands = {}
	for client_id, response in pairs(results_lsp) do
		if response.result then
			local client = vim.lsp.get_client_by_id(client_id)
			for _, result in pairs(response.result) do
				result.client_name = client and client.name or ""
				result.client = client
				table.insert(commands, result)
			end
		end
	end
	show_menu(commands)
end

M.code_action = function()
	M.bufnr = vim.api.nvim_get_current_buf()
	local context = { diagnostics = vim.lsp.diagnostic.get_line_diagnostics() }
	local params = vim.lsp.util.make_range_params()
	params.context = context
	request_code_action(params)
end
M.range_code_action = function()
	M.bufnr = vim.api.nvim_get_current_buf()
	local context = { diagnostics = vim.lsp.diagnostic.get_line_diagnostics() }
	local params = vim.lsp.util.make_given_range_params()
	params.context = context
	request_code_action(params)
end

-- copy from telescope
local function lsp_execute_command(val, offset_encoding)
	-- table.insert(command.arguments,{data=' '})
	-- vim.lsp.buf_request(bn,'workspace/executeCommand', command)
	if val.edit or type(val.command) == "table" then
		if val.edit then
			vim.lsp.util.apply_workspace_edit(val.edit, offset_encoding)
		end
		if type(val.command) == "table" then
			vim.lsp.buf.execute_command(val.command)
		end
	else
		vim.lsp.buf.execute_command(val)
	end
end

-- copy from telescope
local function fix_zero_version(workspace_edit)
	if workspace_edit and workspace_edit.documentChanges then
		for _, change in pairs(workspace_edit.documentChanges) do
			local text_document = change.textDocument
			if text_document and text_document.version and text_document.version == 0 then
				text_document.version = nil
			end
		end
	end
	return workspace_edit
end

-- copy from telescope
local transform_action = function(action)
	local command = (action.command and action.command.command) or action.command
	if not (command == "java.apply.workspaceEdit") then
		return action
	end
	local arguments = (action.command and action.command.arguments) or action.arguments
	action.edit = fix_zero_version(arguments[1])
	return action
end

M.do_action = function(key)
	local data = state.action_tbl
	for _, value in pairs(data) do
		if value.menu_key == key then
			value.menu_key = nil
			vim.api.nvim_win_close(0, true)

			local action = value.data
			local client = action.client
			local eff_execute = function(transformed)
				lsp_execute_command(transformed, client.offset_encoding)
			end

			if
				not action.edit
				and client
				and type(client.resolved_capabilities.code_action) == "table"
				and client.resolved_capabilities.code_action.resolveProvider
			then
				client.request("codeAction/resolve", action, function(resolved_err, resolved_action)
					if resolved_err then
            print('asoifjaoijofew')
						vim.notify(resolved_err.code .. ": " .. resolved_err.message, vim.log.levels.ERROR)
						return
					end
					if resolved_action then
						eff_execute(transform_action(resolved_action))
					else
						eff_execute(transform_action(action))
					end
				end)
			else
				eff_execute(transform_action(action))
			end
			return
		end
	end
end

return M
