local M = {}

M.noop = function() end

M.find_projects = function()
    return vim.fn.systemlist(
        [[{ git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git ls-files || rg -g '!node_modules' --files; } | rg 'tsconfig.*.json']]
    )
end

M.find_monorepo_projects = function()
    local projects = M.find_projects()

    if #projects <= 1 then
        return projects
    end

    return vim.tbl_filter(function(report)
        return project ~= "tsconfig.json"
    end, projects)
end

local function format_message(error, format)
    format = format or "full"

    if type(format) == "function" then
        return format(error.message, error)
    end

    if format == "full" then
        return table.concat(error.message, "\n")
    end

    if format == "first" then
        return error.message[1]
    end

    if format == "last" then
        return vim.trim(error.message[#error.message])
    end

    return format_message(error)
end

M.to_qfitems = function(report)
    return vim.tbl_map(function(error)
        return {
            filename = error.path,
            lnum = error.lnum,
            col = error.col,
            text = format_message(error, message_format),
            type = vim.diagnostic.severity.ERROR,
        }
    end, report)
end

M.to_diagnostics = function(report)
    local result = {}
    for _, error in ipairs(report) do
        local bufnr = vim.fn.bufnr(error.path)
        if bufnr ~= -1 then
            table.insert(result, {
                bufnr = bufnr,
                lnum = error.lnum - 1,
                col = error.col - 1,
                text = format_message(error, message_format),
                severity = vim.diagnostic.severity.ERROR,
                source = "nvim-tsc",
            })
        end
    end
    return result
end

return M
