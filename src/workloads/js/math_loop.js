// math_loop: tight numeric loop. Concession workload.
const N = PARAMS.inner_iters;

function step() {
    let s = 0.0;
    for (let i = 1; i <= N; i++) {
        s = s + Math.sqrt(i) * 0.5;
    }
    return s;
}
