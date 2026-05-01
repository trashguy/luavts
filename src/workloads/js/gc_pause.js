// gc_pause: each tick allocates inner_iters short-lived objects.
const N = PARAMS.inner_iters;

function step() {
    const t = new Array(N);
    for (let i = 0; i < N; i++) {
        t[i] = { x: i, y: i * 2, z: i * 3 };
    }
    return t;
}
