local core = require "fzf-lua.core"
local path = require "fzf-lua.path"
local libuv = require "fzf-lua.libuv"
local utils = require "fzf-lua.utils"
local config = require "fzf-lua.config"
local shell = require "fzf-lua.shell"
local make_entry = require "fzf-lua.make_entry"

local M = {}

local function set_git_cwd_args(opts)
  -- verify cwd is a git repo, override user supplied
  -- cwd if cwd isn't a git repo, error was already
  -- printed to `:messages` by 'path.git_root'
  local git_root = path.git_root(opts)
  if not opts.cwd or not git_root then
    opts.cwd = git_root
  end
  if opts.git_dir or opts.git_worktree then
    opts.cmd = path.git_cwd(opts.cmd, opts)
  end
  return opts
end

M.status = function(opts)
  opts = config.normalize_opts(opts, config.globals.git.status)
  if not opts then return end
  opts = set_git_cwd_args(opts)
  if not opts.cwd then return end
  if opts.preview then
    opts.preview = path.git_cwd(opts.preview, opts)
  end
  -- we don't need git icons since we get them
  -- as part of our `git status -s`
  opts.git_icons = false

  local function git_iconify(x, staged)
    local icon = x
    local git_icon = config.globals.git.icons[x]
    if git_icon then
      icon = git_icon.icon
      if opts.color_icons then
        icon = utils.ansi_codes[staged and "green" or git_icon.color or "dark_grey"](icon)
      end
    end
    return icon
  end

  opts.__fn_transform = opts.__fn_transform or
      function(x)
        -- unrecognizable format, return
        if not x or #x < 4 then return x end
        -- strip ansi coloring or the pattern matching fails
        -- when git config has `color.status=always` (#706)
        x = utils.strip_ansi_coloring(x)
        -- `man git-status`
        -- we are guaranteed format of: XY <text>
        -- spaced files are wrapped with quotes
        -- remove both git markers and quotes
        local f1, f2 = x:sub(4):gsub([["]], ""), nil
        -- renames separate files with '->'
        if f1:match("%s%->%s") then
          f1, f2 = f1:match("(.*)%s%->%s(.*)")
        end
        f1 = f1 and make_entry.file(f1, opts)
        -- accomodate 'file_ignore_patterns'
        if not f1 then return end
        f2 = f2 and make_entry.file(f2, opts)
        local staged = git_iconify(x:sub(1, 1):gsub("?", " "), true)
        local unstaged = git_iconify(x:sub(2, 2))
        local entry = ("%s%s%s%s%s"):format(
          staged, utils.nbsp, unstaged, utils.nbsp .. utils.nbsp,
          (f2 and ("%s -> %s"):format(f1, f2) or f1))
        return entry
      end

  opts.fn_preprocess = opts.fn_preprocess or
      function(o)
        return make_entry.preprocess(o)
      end

  -- we are reusing the "live" reload action, this gets called once
  -- on init and every reload and should return the command we wish
  -- to execute, i.e. `git status -sb`
  opts.__fn_reload = function(_)
    return opts.cmd
  end

  -- build the "reload" cmd and remove '-- {+}' from the initial cmd
  local reload, id = shell.reload_action_cmd(opts, "{+}")
  local contents = reload:gsub("%-%-%s+{%+}$", "")
  opts.__reload_cmd = reload

  -- when the action resumes the preview re-attaches which registers
  -- a new shell function id, done enough times it will overwrite the
  -- regisered function assigned to the reload action and the headless
  -- cmd will err with "sh: 0: -c requires an argument"
  -- gets cleared when resume data recycles
  opts._fn_pre_fzf = function()
    shell.set_protected(id)
  end

  opts.header_prefix = opts.header_prefix or "+ -  "
  opts.header_separator = opts.header_separator or "|"
  opts = core.set_header(opts, opts.headers or { "actions", "cwd" })

  return core.fzf_exec(contents, opts)
end

local function git_cmd(opts)
  opts = set_git_cwd_args(opts)
  if not opts.cwd then return end
  opts = core.set_header(opts, opts.headers or { "cwd" })
  core.fzf_exec(opts.cmd, opts)
end

M.commits = function(opts)
  opts = config.normalize_opts(opts, config.globals.git.commits)
  if not opts then return end
  if opts.preview then
    opts.preview = path.git_cwd(opts.preview, opts)
    if opts.preview_pager then
      opts.preview = string.format("%s | %s", opts.preview, opts.preview_pager)
    end
  end
  opts = core.set_header(opts, opts.headers or { "actions", "cwd" })
  return git_cmd(opts)
end

M.branches = function(opts)
  opts = config.normalize_opts(opts, config.globals.git.branches)
  if not opts then return end
  opts.fzf_opts["--no-multi"] = ""
  if opts.preview then
    opts.__preview = path.git_cwd(opts.preview, opts)
    opts.preview = shell.raw_preview_action_cmd(function(items)
      -- all possible options:
      --   branch
      -- * branch
      --   remotes/origin/branch
      --   (HEAD detached at origin/branch)
      local branch = items[1]:match("[^%s%*]*$"):gsub("%)$", "")
      return opts.__preview:gsub("{.*}", branch)
    end, nil, opts.debug)
  end
  return git_cmd(opts)
end

return M
