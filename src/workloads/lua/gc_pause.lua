-- gc_pause: each tick allocates inner_iters short-lived tables.
-- Host samples per-tick wall time; tail latency reflects GC behavior.

local N = PARAMS.inner_iters

function step()
    local t = {}
    for i = 1, N do
        t[i] = { x = i, y = i * 2, z = i * 3 }
    end
    return t
end
