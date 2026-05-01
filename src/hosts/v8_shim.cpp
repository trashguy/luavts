// Tiny C ABI over V8. Zig calls these via `extern "C"`.
//
// We hold one Isolate + one Context per VM. ICU/StartupData are
// disabled in args.gn; only Platform needs explicit init/teardown.

#include <v8.h>
#include <libplatform/libplatform.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using v8::Context;
using v8::Function;
using v8::HandleScope;
using v8::Isolate;
using v8::Local;
using v8::MaybeLocal;
using v8::Number;
using v8::Object;
using v8::Persistent;
using v8::Script;
using v8::String;
using v8::TryCatch;
using v8::Value;

namespace {

std::unique_ptr<v8::Platform> g_platform;
bool g_inited = false;

struct VM {
    v8::ArrayBuffer::Allocator* allocator = nullptr;
    Isolate* isolate = nullptr;
    Persistent<Context> context;
    // Cached function handles (owned). Looked up once via lvts_get_fn,
    // then called repeatedly via lvts_call_*.
    std::vector<Persistent<Function>*> fns;
};

void die(const char* msg) {
    std::fprintf(stderr, "v8_shim fatal: %s\n", msg);
    std::abort();
}

void report_exception(Isolate* iso, TryCatch& tc) {
    HandleScope hs(iso);
    String::Utf8Value e(iso, tc.Exception());
    std::fprintf(stderr, "v8 exception: %s\n", *e ? *e : "(no message)");
}

}  // namespace

extern "C" {

void lvts_init() {
    if (g_inited) return;
    v8::V8::InitializeICUDefaultLocation("v8_host");
    v8::V8::InitializeExternalStartupData("v8_host");
    g_platform = v8::platform::NewDefaultPlatform();
    v8::V8::InitializePlatform(g_platform.get());
    v8::V8::Initialize();
    g_inited = true;
}

void lvts_shutdown() {
    if (!g_inited) return;
    v8::V8::Dispose();
    v8::V8::DisposePlatform();
    g_platform.reset();
    g_inited = false;
}

void* lvts_create() {
    auto* vm = new VM();
    vm->allocator = v8::ArrayBuffer::Allocator::NewDefaultAllocator();
    Isolate::CreateParams params;
    params.array_buffer_allocator = vm->allocator;
    vm->isolate = Isolate::New(params);
    {
        Isolate::Scope is(vm->isolate);
        HandleScope hs(vm->isolate);
        Local<Context> ctx = Context::New(vm->isolate);
        vm->context.Reset(vm->isolate, ctx);
    }
    return vm;
}

void lvts_destroy(void* handle) {
    auto* vm = static_cast<VM*>(handle);
    if (!vm) return;
    for (auto* p : vm->fns) {
        p->Reset();
        delete p;
    }
    vm->fns.clear();
    vm->context.Reset();
    if (vm->isolate) vm->isolate->Dispose();
    delete vm->allocator;
    delete vm;
}

// Set the global PARAMS object (must be called before lvts_eval).
void lvts_set_params(void* handle, int64_t outer, int64_t inner, int64_t n_agents, int64_t n_ticks, int64_t pressure) {
    auto* vm = static_cast<VM*>(handle);
    Isolate::Scope is(vm->isolate);
    HandleScope hs(vm->isolate);
    Local<Context> ctx = vm->context.Get(vm->isolate);
    Context::Scope cs(ctx);

    Local<Object> p = Object::New(vm->isolate);
    auto setn = [&](const char* k, int64_t v) {
        Local<String> key = String::NewFromUtf8(vm->isolate, k).ToLocalChecked();
        p->Set(ctx, key, Number::New(vm->isolate, static_cast<double>(v))).Check();
    };
    setn("outer_iters", outer);
    setn("inner_iters", inner);
    setn("n_agents", n_agents);
    setn("n_ticks", n_ticks);
    setn("pressure", pressure);

    Local<String> pkey = String::NewFromUtf8(vm->isolate, "PARAMS").ToLocalChecked();
    ctx->Global()->Set(ctx, pkey, p).Check();
}

// Eval a script in the current context. Top-level functions become
// global properties (we use classic-script eval, not module).
int lvts_eval(void* handle, const char* src, size_t len) {
    auto* vm = static_cast<VM*>(handle);
    Isolate::Scope is(vm->isolate);
    HandleScope hs(vm->isolate);
    Local<Context> ctx = vm->context.Get(vm->isolate);
    Context::Scope cs(ctx);
    TryCatch tc(vm->isolate);

    Local<String> source =
        String::NewFromUtf8(vm->isolate, src, v8::NewStringType::kNormal,
                            static_cast<int>(len))
            .ToLocalChecked();
    MaybeLocal<Script> mscript = Script::Compile(ctx, source);
    Local<Script> script;
    if (!mscript.ToLocal(&script)) {
        report_exception(vm->isolate, tc);
        return 1;
    }
    MaybeLocal<Value> mres = script->Run(ctx);
    if (mres.IsEmpty()) {
        report_exception(vm->isolate, tc);
        return 1;
    }
    return 0;
}

// Look up a global function by name and stash a persistent handle.
// Returns its index (>=0) or -1 if not a function.
int lvts_get_fn(void* handle, const char* name) {
    auto* vm = static_cast<VM*>(handle);
    Isolate::Scope is(vm->isolate);
    HandleScope hs(vm->isolate);
    Local<Context> ctx = vm->context.Get(vm->isolate);
    Context::Scope cs(ctx);

    Local<String> key = String::NewFromUtf8(vm->isolate, name).ToLocalChecked();
    Local<Value> v;
    if (!ctx->Global()->Get(ctx, key).ToLocal(&v) || !v->IsFunction()) return -1;
    auto* p = new Persistent<Function>(vm->isolate, v.As<Function>());
    vm->fns.push_back(p);
    return static_cast<int>(vm->fns.size() - 1);
}

int lvts_call_void(void* handle, int fn_idx) {
    auto* vm = static_cast<VM*>(handle);
    Isolate::Scope is(vm->isolate);
    HandleScope hs(vm->isolate);
    Local<Context> ctx = vm->context.Get(vm->isolate);
    Context::Scope cs(ctx);
    TryCatch tc(vm->isolate);

    Local<Function> fn = vm->fns[fn_idx]->Get(vm->isolate);
    Local<Value> recv = ctx->Global();
    MaybeLocal<Value> r = fn->Call(ctx, recv, 0, nullptr);
    if (r.IsEmpty()) { report_exception(vm->isolate, tc); return 1; }
    return 0;
}

int lvts_call_int(void* handle, int fn_idx, int64_t arg) {
    auto* vm = static_cast<VM*>(handle);
    Isolate::Scope is(vm->isolate);
    HandleScope hs(vm->isolate);
    Local<Context> ctx = vm->context.Get(vm->isolate);
    Context::Scope cs(ctx);
    TryCatch tc(vm->isolate);

    Local<Function> fn = vm->fns[fn_idx]->Get(vm->isolate);
    Local<Value> recv = ctx->Global();
    Local<Value> argv[1] = {Number::New(vm->isolate, static_cast<double>(arg))};
    MaybeLocal<Value> r = fn->Call(ctx, recv, 1, argv);
    if (r.IsEmpty()) { report_exception(vm->isolate, tc); return 1; }
    return 0;
}

}  // extern "C"
