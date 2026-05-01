-- tick_budget: ai_tick + per-tick alloc pressure (PARAMS.pressure
-- short-lived tables per tick). Host pairs each call with a Zig-side
-- hot loop and measures total tick wall vs 60Hz/20Hz budgets.

local agents = {}
local n_agents = 0
local pressure = PARAMS.pressure

function init_agents(n)
    n_agents = n
    for i = 1, n do
        agents[i] = {
            x = (i * 31) % 1000,
            y = (i * 17) % 1000,
            tx = ((i + 7) * 13) % 1000,
            ty = ((i + 11) * 19) % 1000,
            hp = 100,
            hostility = (i % 3) - 1,
        }
    end
end

function tick()
    -- Same agent loop as ai_tick.
    for i = 1, n_agents do
        local a = agents[i]
        local dx = a.tx - a.x
        local dy = a.ty - a.y
        local d2 = dx * dx + dy * dy
        if d2 < 25 then
            a.tx = (a.tx * 1103515245 + 12345) % 1000
            a.ty = (a.ty * 1103515245 + 12345) % 1000
        else
            local inv = 1.0 / math.sqrt(d2)
            a.x = a.x + dx * inv
            a.y = a.y + dy * inv
        end
        if a.hostility > 0 then
            a.hp = a.hp - 1
            if a.hp <= 0 then a.hp = 100 end
        end
    end
    -- Per-tick allocation churn — drives GC.
    if pressure > 0 then
        local tmp = {}
        for j = 1, pressure do
            tmp[j] = { a = j, b = j * 2, c = j * 3 }
        end
    end
end
