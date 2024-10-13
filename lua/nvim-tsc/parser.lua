local function parse_report(stdout)
    local lines = vim.split(stdout, "\n", { plain = true })
    local report = {}
    local error

    for _, line in ipairs(lines) do
        local path, ln, col, code, message = line:match("^(.+)%((%d+),(%d+)%): error TS(%d+): (.+)$")
        if path ~= nil then
            error = {
                code = code,
                path = path,
                lnum = tonumber(ln),
                col = tonumber(col),
                message = { message },
            }
            table.insert(report, error)
        elseif error and line ~= "" then
            table.insert(error.message, line)
        end
    end

    return report
end

return function(stdout, watching)
    if stdout == nil or (watching and string.find(stdout, "Watching for file changes")) then
        return { type = "end" }
    end

    if watching and string.find(stdout, "Starting incremental compilation") then
        return { type = "start" }
    end

    local code, message = stdout:match("^error TS(%d+): (.+)$")
    if code ~= nil then
        return { type = "error", data = { code = code, message = message } }
    end

    return { type = "data", data = parse_report(stdout) }
end
