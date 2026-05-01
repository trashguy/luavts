const N_math = PARAMS.inner_iters;

function step_math_loop(): number {
    let s = 0.0;
    for (let i = 1; i <= N_math; i++) {
        s = s + Math.sqrt(i) * 0.5;
    }
    return s;
}

(globalThis as any).step = step_math_loop;
