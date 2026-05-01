// call_overhead: empty step. Round-trip cost only.
function step_call_overhead(): void {}

(globalThis as any).step = step_call_overhead;
