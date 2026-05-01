-- ai_tick: simulates one BT-leaf shape per agent.
-- Each agent has {x, y, target_x, target_y, hp, hostility}.
-- Per tick: read state, compute distance to target, decide action,
-- write back updated state. Mirrors the smallest realistic AI leaf
-- shape: 2-3 table reads, light math, 1-2 writes.

local agents = {}
local n_agents = 0

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
end
