-- math_loop: tight numeric loop. Concession workload — JS JITs are
-- expected to win. Establishes the ceiling difference; doesn't change
-- the embedding-cost argument.

local N = PARAMS.inner_iters

function step()
    local s = 0.0
    for i = 1, N do
        s = s + math.sqrt(i) * 0.5
    end
    return s
end
