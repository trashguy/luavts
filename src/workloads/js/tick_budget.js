// tick_budget: ai_tick + per-tick alloc pressure (PARAMS.pressure
// short-lived objects per tick).

let agents = [];
let n_agents = 0;
const pressure = PARAMS.pressure;

function init_agents(n) {
    n_agents = n;
    agents = new Array(n);
    for (let i = 0; i < n; i++) {
        const k = i + 1;
        agents[i] = {
            x: (k * 31) % 1000,
            y: (k * 17) % 1000,
            tx: ((k + 7) * 13) % 1000,
            ty: ((k + 11) * 19) % 1000,
            hp: 100,
            hostility: (k % 3) - 1,
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
    if (pressure > 0) {
        const tmp = new Array(pressure);
        for (let j = 0; j < pressure; j++) {
            tmp[j] = { a: j, b: j * 2, c: j * 3 };
        }
    }
}
