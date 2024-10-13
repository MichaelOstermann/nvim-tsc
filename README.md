<div align="center">

<h1>nvim-tsc</h1>

**A Neovim plugin to interact with the TypeScript compiler**

</div>

# Features

- Abstraction over the `tsc` command - parses its output and lets you do whatever you want with it
- Global & per-process callbacks that let you know when `tsc` is running or finished
- Concurrency control for *those* megachonker repos (optional)
- Reuses `tsc` processes when constructing new ones (optional)
- Support for `--watch`
- Utilities
  - Find a list of projects (`tsconfig.json` files) for monorepos
  - Access to all currently pending/running processes, including their state
  - Formatters for quickfix/loclist/diagnostics

# Installation

Install the plugin with your preferred package manager:

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "michaelostermann/nvim-tsc",
  lazy = true,
}
```

With options:

```lua
{
  "michaelostermann/nvim-tsc",
  lazy = true,
  opts = {
    -- How many `tsc` commands can spawn at any given moment, default: 2
    -- Note that `--watch` commands are exempt from this!
    max_concurrency = 2,

    -- Called whenever a `tsc` process has been spawned.
    on_start = function(task) end,

    -- Called whenever `tsc` type errors have been extracted.
    on_report = function(report, task) end,

    -- Called whenever an error occurred, such as invalid options passed to `tsc`.
    on_error = function(error, task) end,

    -- Called whenever a `tsc` process has been closed.
    on_exit = function(task) end,
  }
}
```

# Usage

Minimal example:

```lua
local tsc = require("nvim-tsc")

tsc.run({
  on_report = function(report) 
    print(vim.inspect(report))
  end,
})
```

All options with their defaults:

```lua
local tsc = require("nvim-tsc")

local task = tsc.run({
  -- Path to the `tsc` executable. `node_modules/.bin/tsc` or `tsc` if not provided.
  bin = nil,

  -- Path to the project.
  project = "tsconfig.json",

  -- If false, uses `--noEmit`.
  emit = false,

  -- If true, uses `--watch`.
  watch = false,

  -- If true, uses `--incremental`.
  incremental = false,

  -- Additional flags to pass to `tsc`.
  flags = {},

  -- Whether to reuse already pending/running processes instead of this one, if possible.
  dedupe = true,

  -- Whether this task should be queued up and handled according to `max_concurrency`.
  -- If false, `tsc` will run immediately, regardless of how many processes are alive.
  -- Note that this setting is set to false if `watch` is true.
  queue = true,

  -- Called when the process spawned.
  on_start = function(task) end,

  -- Called whenever type errors have been extracted.
  on_report = function(report, task) end,

  -- Called whenever an error occurred, such as invalid options.
  on_error = function(error, task) end,

  -- Called when the process closes.
  on_exit = function(task) end,
})
```

# State

Apart from the options supplied to `tsc.run` as shown above, tasks contain the following properties:

```lua
local task = {
  -- Unique id for this task.
  id = string,

  -- Whether the task has started.
  started = boolean,

  -- Whether the task is currently alive.
  running = boolean,

  -- Whether the task has ended.
  ended = boolean,

  -- For `--watch` tasks, whether we expect more type errors to arrive.
  buffering = boolean,

  -- Whether we have a full report available.
  has_report = boolean,

  -- Timestamp for when the process started.
  -- Refreshed whenever a `--watch` task detected changes and is starting a new run.
  started_at = nil | os.time(),

  -- Timestamp for when the process closed.
  -- Refreshed whenever a `--watch` task detected changes and finished type checking.
  finished_at = nil | os.time(),

  -- A reference to the underlying system call.
  system = nil | vim.system(),

  -- The last error that occurred, such as when a valid `tsc` executable is not available.
  -- `error.code` is a TS error code if `tsc` itself reported the error.
  error = nil | { code: nil | number, message: string }

  -- A list of type errors.
  report = type_error[]
}
```

Extracted type errors have the following shape:

```lua
local type_error = {
  -- The TS error code.
  code = number,

  -- The file path where the error occurred.
  path = string,

  -- The position of the error in the file.
  lnum = number,
  col = number,

  -- The error message split up by newlines. The compiler can spit out multiline
  -- messages and depending on what you want to do, you can display all of them,
  -- or the first/last line. (Often the last line is the most informative one,
  -- with the rest being "Can not assign X to Y").
  message = string[],
}
```

## Utilities

### Tasks

```lua
local tsc = require("nvim-tsc")

-- A record of all known tasks.
tsc.tasks

-- Manually start a task.
tsc.start(task)

-- Manually stop a task.
tsc.stop(task)
```

### Translating reports to qfitems

```lua
local tsc = require("nvim-tsc")

tsc.run({
  on_report = function(report)
    -- Use the full multiline error message:
    local items = tsc.to_qfitems(report)

    -- Use the full multiline error message:
    local items = tsc.to_qfitems(report, "full")

    -- Use only the first line of the error message:
    local items = tsc.to_qfitems(report, "first")

    -- Use only the last line of the error message:
    local items = tsc.to_qfitems(report, "last")

    -- Do your own formatting:
    local items = tsc.to_qfitems(report, function(message, error)
      return message[1]
    end)

    vim.fn.setqflist({}, "r", { items = items })
  end,
})
```

### Translating reports to diagnostics

Please note that neovim diagnostics are bound to buffers - `tsc.to_diagnostics` will filter out any errors that do not have a matching buffer.

```lua
local tsc = require("nvim-tsc")

tsc.run({
  on_report = function(report)
    -- Use the full multiline error message:
    local diagnostics = tsc.to_diagnostics(report)

    -- Use the full multiline error message:
    local diagnostics = tsc.to_diagnostics(report, "full")

    -- Use only the first line of the error message:
    local diagnostics = tsc.to_diagnostics(report, "first")

    -- Use only the last line of the error message:
    local diagnostics = tsc.to_diagnostics(report, "last")

    -- Do your own formatting:
    local diagnostics = tsc.to_diagnostics(report, function(message, error)
      return message[1]
    end)
    
    local nsid = vim.api.nvim_create_namespace("nvim-tsc")
    vim.diagnostic.reset(nsid)

    for _, diagnostic in ipairs(diagnostics) do
      vim.diagnostic.set(nsid, diagnostic.bufnr, { diagnostic }, {})
    end
  end,
})
```

### Finding `tsconfig.json` files

```lua
local tsc = require("nvim-tsc")

-- Command used:
-- { git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git ls-files || rg -g '!node_modules' --files; } | rg 'tsconfig.*.json'
local projects = tsc.find_projects()

-- Same as `find_projects`, but kicks out the root `tsconfig.json` if other ones
-- have been found - usually the root config acts as a base template extended by
-- packages:
local projects = tsc.find_monorepo_projects()

for _, project in ipairs(projects) do
  tsc.run({ project = project })
end
```

# Credits

- [tsc.nvim](https://github.com/dmmulroy/tsc.nvim) by [@dmmulroy](https://github.com/dmmulroy)
