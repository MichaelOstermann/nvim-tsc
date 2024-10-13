local utils = require("nvim-tsc.utils")

return {
    max_concurrency = 2,
    on_start = utils.noop,
    on_report = utils.noop,
    on_error = utils.noop,
    on_end = utils.noop,
}
