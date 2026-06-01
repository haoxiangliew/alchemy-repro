# alchemy-repro — `alchemy dev` silently fails to start all workers (≥3 workers, Bun)

Minimal reproduction of a bug where `alchemy dev` (Alchemy v2 beta) intermittently
fails to fully start one or more Cloudflare Workers in a multi-worker dev session.
The Worker resource reconciles ("✓ updated", `Done: N succeeded`) but the worker
**never prints `Started in Xms` and never serves** — silently, with no error.

## Setup

A Bun workspace monorepo mirroring a realistic setup:

```
packages/
  worker-a/   # Cloudflare.Worker, HttpApi (favicon + hello /), Scalar docs
  worker-b/   # identical
  worker-c/   # identical
  infra/      # alchemy.run.ts — Stack yielding all 3 workers, localState()
```

Each worker is the same `effect/unstable/httpapi` stack used in production
(`HttpApi` + `HttpApiBuilder` + `HttpApiScalar`), exposing:

- `GET /` → `Hello via Bun! - @repro/worker-x`
- `GET /favicon.ico` → 204
- `GET /docs` → Scalar UI

Pinned versions (match the affected project):

- `alchemy@2.0.0-beta.44` → pulls `@distilled.cloud/cloudflare-runtime@0.6.3`
- `effect@4.0.0-beta.74`
- Bun `1.3.13`, `bunfig.toml` → `[run] bun = true`, `[install] linker = "isolated"`

The repo ships the **fix** wired in via `patchedDependencies` (see `patches/`),
so a plain `bun install && bun run dev` is patched/working. The harness can
install the **unpatched** runtime on demand to demonstrate the bug.

The single patch file fixes **two** distinct dev-runtime bugs in
`@distilled.cloud/cloudflare-runtime@0.6.3`:

1. **Worker startup** (`Workerd.mjs` + `find-available-port.mjs`) — a worker
   silently never starts; what the harness reproduces. Two facets of one Bun
   stdio-wiring race (the port-report fd **and** the stdin config pipe). See
   [Fix #1](#fix-1--worker-startup-patches-workerdmjs).
2. **LocalProxy OOM** (`local-proxy.worker.mjs`) — the `:1337` proxy DO crashes
   with a V8 `ExternalEntityTable` out-of-memory. See
   [Fix #2](#fix-2--localproxy-oom).

They **compound**: bug #1 leaves a worker permanently down, and pinging that
worker is the cleanest deterministic trigger for bug #2 (the proxy retries a
`503` for an address that will never appear, forever) — OOM in ~2 minutes. So
this repo reproduces _both_ from one unpatched `bun dev`.

## Reproduce

The harness does a clean install (removes `node_modules` + `.alchemy`, toggles
the patch, `bun install`), then runs `alchemy dev` N times and counts how many
of the 3 workers print `Started in`. Each run waits for the stack to report
`Done:` (the deploy/bundle finished — this absorbs a slow cold-start bundle so
the first run isn't a false negative), then waits `GRACE` seconds for stragglers
to start, returning early once all 3 are up. A run where `Done:` never appears is
reported as `TIMEOUT` and discarded, not counted as a failure. Ctrl-C tears
everything down.

```bash
./run-harness.sh              # unpatched runtime  → the bug
./run-harness.sh --patch      # patched runtime    → the fix
./run-harness.sh 12 4 --both  # entire suite: unpatched then patched (comparison)
```

Positional args: `N` (iterations/suite, default 10), `GRACE` (seconds after
`Done:` to wait for stragglers, default 4).

### Signature of an incomplete run

```
[WorkerA] updated
[WorkerB] updated
[WorkerC] updated
Done: 6 succeeded                       # alchemy thinks everything deployed
[WorkerC] Started in 839ms              # ...but only WorkerC actually serves
                                        # WorkerA + WorkerB: no "Started", no error
```

## Root cause (diagnosed in the parent project)

The dev runtime (`@distilled.cloud/cloudflare-runtime`) spawns one `workerd`
per worker and passes `--control-fd=3`, expecting `workerd` to report its bound
(ephemeral `127.0.0.1:0`) ports back over file descriptor 3. Under Bun,
`child_process.spawn` intermittently fails to wire the 4th stdio pipe (fd ≥ 3)
into a concurrently-spawned child. `workerd` serves fine, but its port-report
goes to a dead fd, so Alchemy never learns the port and never marks the worker
started — the dev session hangs that worker silently.

This race has **two faces**, both the same Bun bug. The control fd (fd 3) is the
one the original fix removed — but pre-allocating ports and dropping fd 3 still
left a residual ~1-in-10 failure (diagnosed in this repro). The runtime also
pipes each worker's serialized config to `workerd` over **stdin (fd 0)**, and the
same concurrent-spawn race intermittently drops _that_ pipe too. When it does,
`workerd` reads EOF, gets no config, and exits `1` within ~4 ms — no stdout, no
stderr, just a silent non-start. The retry loop usually masks it, which is why it
surfaced as the occasional surviving failure rather than every run.

## Fix #1 — worker startup (`patches/`, `Workerd.mjs`)

Remove **both** inherited-pipe dependencies so no fragile fd wiring sits in the
worker startup path:

1. **Ports (fd 3).** Pre-allocate each port in the parent
   (`net.createServer().listen(0)`), rewrite every `127.0.0.1:0` socket to the
   chosen port, and poll readiness via TCP `connect` instead of the fd-3 control
   channel. `workerd` is spawned without `--control-fd=3`, so there's no fd ≥ 3
   for Bun to drop.
2. **Config (fd 0).** Write the serialized config to a temp file and pass its
   path to `workerd serve` instead of piping it over stdin, with `stdio[0]` set
   to `"ignore"`. No stdin pipe means nothing for the race to drop — the config
   is always present when `workerd` reads it.

Together these make startup depend on no inherited pipes at all. (Failure
detection also switched from the process `exit` event to `close`, so `workerd`'s
stderr is fully drained before classification — an empty-stderr crash no longer
gets mislabeled as a generic error.) The port helpers (`allocatePort`,
`isPortAvailable`) live in `internal/find-available-port.mjs`, so the patch also
touches that file. `./run-harness.sh --patch` confirms 10/10; ad-hoc dev loops
run 60/60.

```
❯ ./run-harness.sh 20 --both

>>> Preparing 'unpatched' suite: clean node_modules + .alchemy, toggle patch, bun install
    runtime: UNPATCHED (--control-fd=3, fd-3 port report)

############ SUITE: unpatched  (N=20, grace=4s) ############
  [unpatched] RUN  1: started=3/3  [WorkerA,WorkerB,WorkerC]
  [unpatched] RUN  2: started=0/3  []   <<< INCOMPLETE
  [unpatched] RUN  3: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  4: started=2/3  [WorkerB,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  5: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  6: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  7: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  8: started=1/3  [WorkerC]   <<< INCOMPLETE
  [unpatched] RUN  9: started=1/3  [WorkerA]   <<< INCOMPLETE
  [unpatched] RUN 10: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 11: started=1/3  [WorkerA]   <<< INCOMPLETE
  [unpatched] RUN 12: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 13: started=2/3  [WorkerA,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 14: started=2/3  [WorkerB,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 15: started=2/3  [WorkerB,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 16: started=3/3  [WorkerA,WorkerB,WorkerC]
  [unpatched] RUN 17: started=1/3  [WorkerA]   <<< INCOMPLETE
  [unpatched] RUN 18: started=2/3  [WorkerB,WorkerC]   <<< INCOMPLETE
  [unpatched] RUN 19: started=1/3  [WorkerA]   <<< INCOMPLETE
  [unpatched] RUN 20: started=2/3  [WorkerA,WorkerB]   <<< INCOMPLETE
  --- unpatched distribution (valid samples) ---
    0/3 -> 1 run(s)
    1/3 -> 5 run(s)
    2/3 -> 12 run(s)
    3/3 -> 2 run(s)
  >>> unpatched: 2/20 valid runs started ALL 3 workers

>>> Preparing 'patched' suite: clean node_modules + .alchemy, toggle patch, bun install
    runtime: PATCHED (port pre-alloc + TCP readiness poll, no --control-fd)

############ SUITE: patched  (N=20, grace=4s) ############
  [patched] RUN  1: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  2: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  3: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  4: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  5: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  6: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  7: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  8: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN  9: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 10: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 11: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 12: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 13: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 14: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 15: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 16: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 17: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 18: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 19: started=3/3  [WorkerA,WorkerB,WorkerC]
  [patched] RUN 20: started=3/3  [WorkerA,WorkerB,WorkerC]
  --- patched distribution (valid samples) ---
    3/3 -> 20 run(s)
  >>> patched: 20/20 valid runs started ALL 3 workers

================= SUMMARY =================
  unpatched: 2/20 valid runs started all 3 (0 timed out)
  patched: 20/20 valid runs started all 3 (0 timed out)
```

## Fix #2 — LocalProxy OOM

**Fixed Upstream**: https://github.com/alchemy-run/cloudflare-tools/pull/34

(`patches/`, `local-proxy.worker.mjs`)

The same patch file carries a second fix. The `run-harness.sh` flow doesn't hit
it (it kills each run within seconds), but it **is** reproducible in this repo by
hand — and bug #1 makes it deterministic (see _Reproduce_ below).

**Symptom.** `alchemy dev` with ≥2 workers crashed the dev runtime after ~2
minutes with a V8 fatal `ExternalEntityTable::AllocateEntry: allocation failed:
process out of memory`. The crash was in the **`:1337` proxy Durable Object**
(declared `preventEviction: true`, so it never resets), not in any worker — so
when it died, **every** `*.localhost:1337` URL went down at once. It scaled with
worker count (stable with 1 worker; died reliably with 3).

**Reproduce (unpatched):**

```
# install unpatched, then run dev
jq 'del(.patchedDependencies)' package.json > package.json.tmp && mv package.json.tmp package.json && bun i
❯ bun dev
# wait for the startup bug to leave one worker down (e.g. only A + B print "Started")
# then ping the worker that never started — its proxy address is never set:

$ bun run --filter '@repro/infra' --elide-lines=0 dev
@repro/infra dev $ alchemy dev
│ Plan: 3 to create
│ [WorkerA] create
│ [WorkerB] create
│ [WorkerC] create
│
│ [WorkerA] pending
│ [WorkerA] creating
│ [WorkerC] pending
│ [WorkerC] creating
│ [WorkerB] pending
│ [WorkerB] creating
│ [WorkerA] created
│ [WorkerC] created
│ [WorkerB] created
│ [WorkerA] created
│ [WorkerC] created
│ [WorkerB] created
│
│ Done: 6 succeeded
│ {
│   workerA: {
│     workerId: "repro-workera-dev-haoxiangliew-wos373rt5acpquft",
│     workerName: "repro-workera-dev-haoxiangliew-wos373rt5acpquft",
│     logpush: undefined,
│     url: "http://workera.localhost:1337",
│     tags: [],
│     durableObjectNamespaces: {},
│     domains: [],
│     crons: [],
│     accountId: "d2b22b519688c6250cbabb867379676e",
│   },
│   workerB: {
│     workerId: "repro-workerb-dev-haoxiangliew-m6o3fm6dpzgjaaii",
│     workerName: "repro-workerb-dev-haoxiangliew-m6o3fm6dpzgjaaii",
│     logpush: undefined,
│     url: "http://workerb.localhost:1337",
│     tags: [],
│     durableObjectNamespaces: {},
│     domains: [],
│     crons: [],
│     accountId: "d2b22b519688c6250cbabb867379676e",
│   },
│   workerC: {
│     workerId: "repro-workerc-dev-haoxiangliew-kymsrthygibcycbp",
│     workerName: "repro-workerc-dev-haoxiangliew-kymsrthygibcycbp",
│     logpush: undefined,
│     url: "http://workerc.localhost:1337",
│     tags: [],
│     durableObjectNamespaces: {},
│     domains: [],
│     crons: [],
│     accountId: "d2b22b519688c6250cbabb867379676e",
│   },
│ }
│ [13:54:11.092] INFO (#29): [WorkerB] Started in 885ms
│ [13:54:11.127] INFO (#27): [WorkerA] Started in 921ms
│

curl http://workerc.localhost:1337/        # hangs (retryable 503, retried forever)
# ~2 min later the :1337 proxy aborts with the stack trace below.

│ <--- Last few GCs --->
│
│ [25163:0xc26820000]   128559 ms: Scavenge 4.7 (9.8) -> 0.7 (9.8) MB, pooled: 0.0 MB, 0.09 / 0.00 ms (average mu = 1.000, current mu = 1.000) allocation failure;
│ [25163:0xc26820000]   128567 ms: Scavenge 4.7 (9.8) -> 0.7 (9.8) MB, pooled: 0.0 MB, 0.08 / 0.00 ms (average mu = 1.000, current mu = 1.000) allocation failure;
│ [25163:0xc26820000]   128576 ms: Scavenge 4.7 (9.8) -> 0.7 (9.8) MB, pooled: 0.0 MB, 0.09 / 0.00 ms (average mu = 1.000, current mu = 1.000) allocation failure;
│
│ workerd/jsg/setup.c++:38: fatal: V8 fatal error; location = ExternalEntityTable::AllocateEntry; message = : allocation failed: process out of memory
│
│ *** Received signal #6: Abort trap: 6
│ stack: 18a4a98d7 18a3b0643 1019382a3 101d9c1c7 101d9c177 101db5957 101db3ac7 101da9403 101943a47 100a82433 101dfdaf7 101dfd163 101c5560b 101ba63af 15000af63 15000bd93 101be8f63 101cd86b7 101bd8257 101ba6f9b 101eeb2af 101eebbd3 101eebd13 101f00f33 101f00d9f 10190cf23 10123bee3 10123bab7 101234da3

# restore: git checkout package.json && bun i
```

This is the cleanest trigger: a worker that _never_ starts (bug #1) keeps the
proxy's `localAddress` for it permanently unset, so the request stays retryable
`503` forever and the hot-loop never stops — versus a merely slow-starting worker,
where the window closes once it comes up. Under the patch, the curl just retries
every 50 ms and succeeds the instant the worker is up (or returns promptly if it
never will), and the proxy holds bounded memory.

**Root cause.** The proxy's retry machinery used a generator that did
`yield* this.retryRequestQueue` over a **live `Map`**. On a transient `503`
(thrown when a worker's `localAddress` isn't set yet — i.e. during startup /
hot-reload), the handler re-`set` the request **into the same Map being
iterated**, so the iterator immediately revisited it — **no `await`, no timer,
no yield to the event loop**. That microtask-speed spin allocated V8
external-pointer-table entries (`new URL`, `new Headers`, `fetch` handles, …)
faster than GC could reclaim them, until the table filled and workerd aborted.
A fire-and-forget `processRequestQueue()` per request multiplied the spin across
concurrent loops sharing the same Maps.

**The fix.** Replace the queue-driven retry with a self-contained per-request
loop that backs off 50 ms between attempts:

```js
async fetchUserWorker(request) {
  while (true) {
    try {
      return await this.routeUserWorkerRequest(request);
    } catch (cause) {
      const error = ProxyError.fromUnknown(cause);
      if (!error.retryable) return error.toResponse();
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
}
```

No shared mutable Maps to mutate-during-iteration, and every retry yields to the
event loop — so allocations can't outrun GC. Semantics are preserved (retry
retryable `503`s until ready; resolve non-retryable errors immediately; WS
upgrade path untouched); the only cost is ≤50 ms of extra latency on the
worker-still-starting path. The now-unused `requestQueue` / `retryRequestQueue`
/ `processRequestQueue` / `getOrderedRequestQueue` are left as dead code (the
patch edits the minified `content` string, so the smallest safe edit is a
single-method-body replacement). Verified: the proxy survived 3.5 min of brutal
load with bounded RSS (~100–160 MB sawtooth) and <4% CPU, well past the ~2 min
pre-patch crash point.

> Both bugs also exist in upstream HEAD (the proxy logic relocated to
> `WorkerProxy.worker.ts`); neither is being filed upstream. The patch targets
> `0.6.3` exactly — bumping the dependency requires re-creating it.
