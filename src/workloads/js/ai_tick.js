// ai_tick: same shape as the Lua workload. Each agent has
// {x, y, tx, ty, hp, hostility}. Per tick: read state, distance to
// target, decide action, write back.

let agents = [];
let n_agents = 0;

function init_agents(n) {
    n_agents = n;
    agents = new Array(n);
    for (let i = 0; i < n; i++) {
        agents[i] = {
            x: ((i + 1) * 31) % 1000,
            y: ((i + 1) * 17) % 1000,
            tx: (((i + 1) + 7) * 13) % 1000,
            ty: (((i + 1) + 11) * 19) % 1000,
            hp: 100,
            hostility: ((i + 1) % 3) - 1,
        };
    }
}

function tick() {
    for (let i = 0; i < n_agents; i++) {
        const a = agents[i];
        const dx = a.tx - a.x;
        const dy = a.ty - a.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < 25) {
            a.tx = (a.tx * 1103515245 + 12345) % 1000;
            a.ty = (a.ty * 1103515245 + 12345) % 1000;
        } else {
            const inv = 1.0 / Math.sqrt(d2);
            a.x = a.x + dx * inv;
            a.y = a.y + dy * inv;
        }
        if (a.hostility > 0) {
            a.hp = a.hp - 1;
            if (a.hp <= 0) a.hp = 100;
        }
    }
}
