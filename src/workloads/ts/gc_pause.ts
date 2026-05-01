const N_gc = PARAMS.inner_iters;

function step_gc_pause(): unknown {
    const t: { x: number; y: number; z: number }[] = [];
    for (let i = 0; i < N_gc; i++) {
        t[i] = { x: i, y: i * 2, z: i * 3 };
    }
    return t;
}

(globalThis as any).step = step_gc_pause;
