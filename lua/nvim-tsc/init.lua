local os = require("os")
local parser = require("nvim-tsc.parser")
local config = require("nvim-tsc.config")
local utils = require("nvim-tsc.utils")

local M = {}
local tasks = {}
local queue = {}
local id = 0

M.tasks = tasks
M.find_projects = utils.find_projects
M.find_monorepo_projects = utils.find_monorepo_projects
M.to_qfitems = utils.to_qfitems
M.to_diagnostics = utils.to_diagnostics

local function compose(left, right)
    if left == utils.noop then
        return right
    end

    if right == utils.noop then
        return left
    end

    return function(...)
        left(...)
        right(...)
    end
end

local function fallback(value, if_nil)
    if value == nil then
        return if_nil
    else
        return value
    end
end

local function is_executable(cmd)
    return cmd and vim.fn.executable(cmd) == 1 or false
end

local function find_tsc_bin()
    local path = vim.fn.findfile("node_modules/.bin/tsc", ".;")
    if path ~= "" then
        return path
    end
    return "tsc"
end

M.run = function(opts)
    id = id + 1

    local task = {
        id = tostring(id),
        -- Options
        bin = opts.bin or find_tsc_bin(),
        project = opts.project or "tsconfig.json",
        emit = fallback(opts.emit, false),
        watch = fallback(opts.watch, false),
        incremental = fallback(opts.incremental, false),
        queue = fallback(opts.queue, true),
        dedupe = fallback(opts.dedupe, true),
        flags = opts.flags or {},
        -- Callbacks
        on_start = opts.on_start or utils.noop,
        on_report = opts.on_report or utils.noop,
        on_error = opts.on_error or utils.noop,
        on_end = opts.on_end or utils.noop,
        -- State
        started = false,
        running = false,
        ended = false,
        buffering = false,
        has_report = false,
        started_at = nil,
        finished_at = nil,
        system = nil,
        error = nil,
        report = {},
    }

    -- Translate flags to options, just in case.
    if vim.list_contains(task.flags, "--noEmit") then
        task.emit = false
    end
    if vim.list_contains(task.flags, "--watch") then
        task.watch = true
    end
    if vim.list_contains(task.flags, "--incremental") then
        task.incremental = true
    end

    -- Remove flags for which there are options.
    task.flags = vim.tbl_filter(function(flag)
        return not vim.list_contains({ "--noEmit", "--watch", "--incremental" }, flag)
    end, task.flags)

    -- Disable queue if this is a --watch task.
    task.queue = task.queue and not task.watch

    -- Build the cmd to be passed to `vim.system`.
    task.cmd = { task.bin }
    if not task.emit then
        table.insert(task.cmd, "--noEmit")
    end
    if task.watch then
        table.insert(task.cmd, "--watch")
    end
    if task.incremental then
        table.insert(task.cmd, "--incremental")
    end
    vim.list_extend(task.cmd, { "--project", task.project })
    vim.list_extend(task.cmd, task.flags)

    -- Abort mission if we dont't have a valid `tsc` executable.
    if not is_executable(task.bin) then
        task.error = {
            code = nil,
            message = "tsc was not available or found in your node_modules or $PATH. Please run install and try again.",
        }
        task.on_error(task.error, task)
        config.on_error(task.error, task)
        return task
    end

    -- Try to find an identical task that already exists and reuse it.
    if task.dedupe then
        for _, existing_task in ipairs(tasks) do
            if vim.deep_equal(task.cmd, existing_task.cmd) then
                -- Copy over callbacks.
                existing_task.on_start = compose(existing_task.on_start, task.on_start)
                existing_task.on_report = compose(existing_task.on_report, task.on_report)
                existing_task.on_error = compose(existing_task.on_error, task.on_error)
                existing_task.on_end = compose(existing_task.on_end, task.on_end)
                -- Fire callbacks for events that already happened.
                if existing_task.started then
                    task.on_start(existing_task)
                end
                if existing_task.has_report then
                    task.on_report(existing_task.report, existing_task)
                end
                if existing_task.error then
                    task.on_error(existing_task.error, existing_task)
                end
                if existing_task.ended then
                    task.on_end(existing_task)
                end
                return existing_task
            end
        end
    end

    tasks[task.id] = task

    if task.queue then
        table.insert(queue, task)
        M.flush()
    else
        M.start(task)
    end

    return task
end

M.start = function(task)
    if task.started then
        return
    end

    task.started_at = os.time()
    task.started = true
    task.running = true

    task.system = vim.system(task.cmd, {
        text = true,
        stdout = function(_, output)
            -- M.stop(task) was used, ignore.
            if not task.running then
                return
            end

            local result = parser(output, task.watch)

            if result.type == "start" then
                task.has_report = false
                task.buffering = true
                task.report = {}
                task.started_at = os.time()
                task.finished_at = nil
            elseif result.type == "data" then
                vim.list_extend(task.report, result.data)
            elseif result.type == "end" then
                task.has_report = true
                task.buffering = false
                task.finished_at = os.time()
                task.on_report(task.report, task)
                config.on_report(task.report, task)
            elseif result.type == "error" then
                task.has_report = true
                task.buffering = false
                task.finished_at = os.time()
                task.report = {}
                task.error = result.data
                task.on_report(task.report, task)
                config.on_report(task.report, task)
                task.on_error(task.error, task)
                config.on_error(task.error, task)
            end
        end,
    }, function()
        task.system = nil
        task.ended = true
        task.running = false
        tasks[task.id] = nil
        task.on_end(task)
        config.on_end(task)
        M.flush()
    end)

    task.on_start(task)
    config.on_start(task)
end

M.stop = function(task)
    if not task.started then
        return
    end

    task.running = false
    task.ended = true
    task.system:kill()
    task.system = nil
    tasks[task.id] = nil
    M.flush()
end

M.flush = function()
    if #queue == 0 then
        return
    end

    local active_count = #vim.tbl_filter(function(task)
        return task.queue and task.running
    end, vim.tbl_values(tasks))

    if active_count >= config.max_concurrency then
        return
    end

    local task = table.remove(queue, 1)

    if task.queue and not task.started and not task.running and not task.ended then
        M.start(task)
    else
        M.flush()
    end
end

M.setup = function(opts)
    for key, value in pairs(opts) do
        config[key] = value
    end

    assert_true(type(config.max_concurrency) == "number", "nvim-tsc setup: max_concurrency is not a number")
    assert_true(config.max_concurrency > 0, "nvim-tsc setup: max_concurrency must be > 0")
    assert_true(type(config.on_start) == "function", "nvim-tsc setup: on_start is not a function")
    assert_true(type(config.on_report) == "function", "nvim-tsc setup: on_report is not a function")
    assert_true(type(config.on_error) == "function", "nvim-tsc setup: on_error is not a function")
    assert_true(type(config.on_end) == "function", "nvim-tsc setup: on_end is not a function")
end

return M
