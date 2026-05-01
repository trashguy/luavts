// ai_tick — TS source. Compiled to Lua via TSTL and to JS via tsc.
// Same algorithm as workloads/lua/ai_tick.lua and workloads/js/ai_tick.js.

interface Agent {
    x: number;
    y: number;
    tx: number;
    ty: number;
    hp: number;
    hostility: number;
}

let agents: Agent[] = [];
let n_agents = 0;

function init_agents(n: number): void {
    n_agents = n;
    agents = [];
    for (let i = 1; i <= n; i++) {
        agents[i - 1] = {
            x: (i * 31) % 1000,
            y: (i * 17) % 1000,
            tx: ((i + 7) * 13) % 1000,
            ty: ((i + 11) * 19) % 1000,
            hp: 100,
            hostility: (i % 3) - 1,
        };
    }
}

function tick(): void {
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

(globalThis as any).init_agents = init_agents;
(globalThis as any).tick = tick;
