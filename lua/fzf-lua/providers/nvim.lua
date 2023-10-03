local core = require "fzf-lua.core"
local path = require "fzf-lua.path"
local utils = require "fzf-lua.utils"
local shell = require "fzf-lua.shell"
local config = require "fzf-lua.config"
local make_entry = require "fzf-lua.make_entry"

local M = {}

M.commands = function(opts)
  opts = config.normalize_opts(opts, config.globals.commands)
  if not opts then return end

  local global_commands = vim.api.nvim_get_commands {}
  local buf_commands = vim.api.nvim_buf_get_commands(0, {})
  local commands = vim.tbl_extend("force", {}, global_commands, buf_commands)

  local prev_act = shell.action(function(args)
    local cmd = args[1]
    if commands[cmd] then
      cmd = vim.inspect(commands[cmd])
    end
    return cmd
  end, nil, opts.debug)

  local entries = {}

  if opts.sort_lastused then
    -- display last used commands at the top of the list (#748)
    -- iterate the command history from last used backwards
    -- each command found gets added to the top of the list
    -- and removed from the command map
    local history = vim.split(vim.fn.execute("history"), "\n")
    for i = #history, #history - 3, -1 do
      local cmd = history[i]:match("%d+%s+([^%s]+)")
      if buf_commands[cmd] then
        table.insert(entries, utils.ansi_codes.green(cmd))
        buf_commands[cmd] = nil
      end
      if global_commands[cmd] then
        table.insert(entries, utils.ansi_codes.magenta(cmd))
        global_commands[cmd] = nil
      end
    end
  end

  for k, _ in pairs(global_commands) do
    table.insert(entries, utils.ansi_codes.magenta(k))
  end

  for k, v in pairs(buf_commands) do
    if type(v) == "table" then
      table.insert(entries, utils.ansi_codes.green(k))
    end
  end

  if not opts.sort_lastused then
    table.sort(entries, function(a, b) return a < b end)
  end

  opts.fzf_opts["--no-multi"] = ""
  opts.fzf_opts["--preview"] = prev_act

  core.fzf_exec(entries, opts)
end

local history = function(opts, str)
  local history = vim.fn.execute("history " .. str)
  history = vim.split(history, "\n")

  local entries = {}
  for i = #history, 3, -1 do
    local item = history[i]
    local _, finish = string.find(item, "%d+ +")
    table.insert(
      entries,
      opts.reverse_list and 1 or #entries + 1,
      string.sub(item, finish + 1))
  end

  opts.fzf_opts["--no-multi"] = ""

  core.fzf_exec(entries, opts)
end

local arg_header = function(sel_key, edit_key, text)
  sel_key = utils.ansi_codes.yellow(sel_key)
  edit_key = utils.ansi_codes.yellow(edit_key)
  return vim.fn.shellescape((":: %s to %s, %s to edit")
    :format(sel_key, text, edit_key))
end

M.keymaps = function(opts)
  opts = config.normalize_opts(opts, config.globals.keymaps)
  if not opts then return end

  local formatter = opts.formatter or "%s │ %-14s │ %-33s │ %s"
  local key_modes = opts.modes or { "n", "i", "c", "v", "t" }
  local modes = {
    n = "blue",
    i = "red",
    c = "yellow",
    v = "magenta",
    t = "green"
  }
  local keymaps = {}


  local add_keymap = function(keymap)
    -- ignore dummy mappings
    if type(keymap.rhs) == "string" and #keymap.rhs == 0 then
      return
    end

    -- by default we ignore <SNR> and <Plug> mappings
    if type(keymap.lhs) == "string" and type(opts.ignore_patterns) == "table" then
      for _, p in ipairs(opts.ignore_patterns) do
        -- case insensitive pattern match
        local pattern, lhs = p:lower(), vim.trim(keymap.lhs:lower())
        if lhs:match(pattern) then
          return
        end
      end
    end

    keymap.str = string.format(formatter,
      utils.ansi_codes[modes[keymap.mode] or "blue"](keymap.mode),
      keymap.lhs:gsub("%s", "<Space>"),
      -- desc can be a multi-line string, normalize it
      string.sub(string.gsub(keymap.desc or "", "\n%s+", "\r") or "", 1, 30),
      (keymap.rhs or string.format("%s", keymap.callback)))

    local k = string.format("[%s:%s:%s]", keymap.buffer, keymap.mode, keymap.lhs)
    keymaps[k] = keymap
  end

  for _, mode in pairs(key_modes) do
    local global = vim.api.nvim_get_keymap(mode)
    for _, keymap in pairs(global) do
      add_keymap(keymap)
    end
    local buf_local = vim.api.nvim_buf_get_keymap(0, mode)
    for _, keymap in pairs(buf_local) do
      add_keymap(keymap)
    end
  end

  local entries = {}
  for _, v in pairs(keymaps) do
    table.insert(entries, v.str)
  end

  opts.fzf_opts["--no-multi"] = ""
  opts.fzf_opts["--header-lines"] = "1"

  -- sort alphabetically
  table.sort(entries)

  local header_str = string.format(formatter, "m", "keymap", "description", "detail")
  table.insert(entries, 1, header_str)

  core.fzf_exec(entries, opts)
end

M.autocmds = function(opts)
  opts = config.normalize_opts(opts, config.globals.autocmds)
  if not opts then return end

  local autocmds = vim.api.nvim_get_autocmds({})
  if not autocmds or vim.tbl_isempty(autocmds) then
    return
  end

  local contents = function(cb)
    coroutine.wrap(function()
      local co = coroutine.running()
      for _, a in ipairs(autocmds) do
        local file, line = "<none>", 0
        if a.callback then
          local info = debug.getinfo(a.callback, "S")
          file = info and info.source and info.source:sub(2) or ""
          line = info and info.linedefined or 0
        end
        local group = a.group_name and vim.trim(a.group_name) or " "
        local entry = string.format("%s:%d:%-28s │ %-34s │ %-18s │ %s",
          file, line,
          utils.ansi_codes.yellow(a.event),
          utils.ansi_codes.blue(group),
          a.pattern,
          a.callback and utils.ansi_codes.red(tostring(a.callback)) or a.command)
        cb(entry, function(err)
          coroutine.resume(co)
          if err then cb(nil) end
        end)
        coroutine.yield()
      end
      cb(nil)
    end)()
  end

  return core.fzf_exec(contents, opts)
end

return M
