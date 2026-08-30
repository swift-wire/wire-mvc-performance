# wire-mvc-performance

A benchmark harness isolating **where WireMVC's per-request cost goes** — its own tiers, the HTTP server
under it, or the `ServerTransport` bridge that mounts it on Hummingbird and Vapor.

It exists because the question kept being argued rather than measured, and because the first attempts to
measure it produced two contradictory answers. Both were wrong for the same reason: they compared numbers
taken with *different harnesses*.

## Results

Every scenario runs **alone** — one server alive at a time — in six short rounds, visited in a different
order each round. That matters more than it sounds: see [the ordering
problem](#the-ordering-problem-and-what-it-invalidated), which produced a reproducible ~3 µs of fake signal
until it was found.

Numbers below are p50 from a representative run, with the range across three runs where it is wide.

### The floors — the servers themselves, routerless

| server | min | p50 | p90 | p99 |
|---|---|---|---|---|
| `vapor-raw` | 60.08 | **69.04** | 76.46 | 85.67 |
| `hummingbird-raw` | 65.46 | **73.21** | 79.42 | 91.50 |
| `proposal-plain` | 68.75 | **78.00** | 83.54 | 95.17 |

The proposal server is ~5 µs above Hummingbird's and ~9 above Vapor's, consistently. Why is not measured
here — the handlers differ slightly (the proposal one drains its reader explicitly) and nothing has been
attributed inside the server.

### What each router costs, against its own routerless floor

| router | min | p50 | p50 across runs |
|---|---|---|---|
| **WireMVC's** | +2.25 | **+0.54** | −0.17 … +0.54 |
| Hummingbird's | −0.21 | **+0.71** | +0.71 … +1.21 |
| Vapor's | +2.54 | **+3.33** | +3.33 … +3.54 |

WireMVC's router and Hummingbird's are within a microsecond of each other and of zero; Vapor's is
reproducibly ~3.4 µs. That ordering is stable across runs, unlike anything measured before the driver was
fixed.

### One contributed response header

Each framework adds one field on the way out, through whatever mechanism it offers, priced against its own
plain routed scenario.

Re-measured 2026-08-26 against wire-mvc `1cae23d`, six runs, each scenario alone in six shuffled rounds.
Median p50 across the six, with the spread beside it:

| mechanism | p50 | across 6 runs | previously |
|---|---|---|---|
| Hummingbird `RouterMiddleware` | **+0.65** | +0.38 … +2.08 | +0.50 |
| Vapor `Middleware` (future-based) | **+0.98** | +0.21 … +1.29 | +1.25 |
| **WireMVC registry + applying** | **+1.96** | +1.62 … +3.21 | +1.42 |
| Vapor `AsyncMiddleware` | **+15.92** | +15.54 … +16.75 | +15.92 |

**`min` is no longer quoted, because it is not a measurement at this scale.** Across the six runs it ranged
from −12.96 to +14.04 for the same row: a fastest-sample-minus-fastest-sample difference between two
separately-driven scenarios is noise, and quoting it invited reading a negative cost into it. p50 with its
spread is what this comparison can support.

**The ordering is unchanged and every row is within its own spread of the previous figures.** Vapor's
`AsyncMiddleware` reproduces at *exactly* +15.92, which is the control: the machine and harness are
comparable to the run these numbers replace, so the smaller movements elsewhere are noise rather than
drift.

**The WireMVC-vs-Hummingbird gap in that table is mostly not real, and the socketed measurement cannot
settle it.** Their spreads overlap (+1.62…+3.21 against +0.38…+2.08): the noise is ±1.6 µs and the
claimed difference is ~1.3. The row is also **not scope-matched** the way Hummingbird's is:
`proposal-headers` serves on `WireMVCContextServer` while `proposal-routed` serves on the bare server, so
it charges WireMVC
for the courier layer as well as the header mechanism, which is the same mistake `proposal-routed` exists
to have stopped making for the router row.

The in-process pair is scope-matched and resolves ~0.05 µs. Against it the whole mechanism is
**+0.41 µs**, and the ladder says what of:

| rung | p50 | what it adds |
|---|---|---|
| `+outcome` → `+reg-add` | **+0.00** | creating the registry and registering a contribution |
| `+reg-add` → `+drain-only` | **+0.04 … +0.08** | draining it |
| `+drain-only` → `+resolve` | **+0.29** | applying the drained contribution into `HTTPFields` |
| `routed-match` → `courier-headers` | **+0.41 … +0.46** | all of it, end to end |

**That +0.29 is the field insertion, and Hummingbird pays it too.** `+fields-1` − `+fields-0` — an
outcome with one header field against one with none, no registry, no drain, no resolve — measures
**+0.25 … +0.29** independently. Hummingbird's middleware body is `response.headers[name] = value`: the
same subscript on the same `HTTPFields` type.

**Put both frameworks on that instrument.** `hb-plain` / `hb-headers` drive Hummingbird's own router and
middleware through `buildResponder()`, no socket, same clock and same round structure as the WireMVC pair:

| mechanism, in process | p50 | across 6 runs |
|---|---|---|
| Hummingbird `RouterMiddleware` | **+0.29** | +0.29 … +0.29 |
| **WireMVC registry + applying** | **+0.41** | +0.37 … +0.58 |

**Hummingbird's mechanism is the field insertion and nothing else** — its +0.29 lands exactly on the
`+fields-1` − `+fields-0` figure, arrived at from the other direction. WireMVC's +0.41 is that same
insertion plus its drain, and the ~0.12 between them is the registry: what it costs to register a
contribution on the way in and evaluate it on the way out, rather than mutating a response that already
exists.

So the honest gap is **about a tenth of a microsecond**, not the ~1.3 the socketed rows imply, and it is
in the direction the design predicts.

**Splitting that tenth: about a third is the registry's size and two thirds is the indirection.** Making
the registry `~Copyable` turned an 8-byte class pointer into a **240-byte value**, moved about five times
per request — courier, `takeContents`, into the box, out of the destructure, into the wrapper. Shrinking it
by lowering the inline capacity measures the cost of that directly:

| `inlineCapacity` | registry size | mechanism |
|---|---|---|
| 4 (shipped) | 240 B | +0.41 |
| 2 | 128 B | +0.37 … +0.41 |
| 1 | 72 B | **+0.37** |

A 3.3× smaller value buys about one timer tick. **Not taken, and the reason is the trade rather than the
size:** `CORSMiddleware` contributes up to four fields, so capacity 1 sends it to the overflow array and
puts an allocation back exactly where the inline storage earns its place; capacity 2 measures no better
than 4. The size is a real cost with no good lever on it.

The remaining ~0.08 is the register-now-apply-later shape itself. Hummingbird writes `fields[name] =
value` at the moment it holds the response; WireMVC has to store a *description* of the operation, carry
it, then walk the registrations and dispatch on the case (`.set` / `.append` / `.setIfAbsent`) to replay
it. That is what buys the head going out as soon as the handler decides it, and it is not free. Whether it
is irreducible is untested — the obvious lever is a fast path for the overwhelmingly common case, one
`.value` registration with no deferred and no overflow, applied without the walk. By the arithmetic above
that is worth perhaps 0.03 … 0.05 µs, which is small enough that it should be measured before it is
written rather than after.

**None of this is worth doing.** The whole 0.12 is under 0.2% of the ~78 µs a real request costs, against a
bridge at 16–47 µs. It is documented so the number has an explanation attached, not because it is an
opportunity.

> **These two rows were wrong here until the driver was fixed, and the error was 15 µs.**
> `HTTPResponder.respond` is `@Sendable`, this package enables `NonisolatedNonsendingByDefault` and
> Hummingbird does not, so driving it from a `nonisolated(nonsending)` caller hopped to the global executor
> and back on every request — twice, counting the body write. `hb-plain` read **15.9 µs** against
> `routed-match`'s 0.88, and the header delta was a small difference between two hop-laden numbers, noisy
> enough (+0.21 … +0.75) to have been published as "Hummingbird +0.59, marginally dearer than WireMVC".
> Marking the driver `@concurrent` puts it on the executor the call already wants — which is where a real
> server drives it from, and why the socketed rows never showed this — and `hb-plain` drops to **1.02 µs**,
> next to `routed-match`'s 0.88. The WireMVC cases were checked for the same fault and do not have it:
> `HTTPServerRequestHandler.handle` is `nonisolated(nonsending)`, so `routed-match` measures 0.88 on either
> executor.

That ~0.12 is not the field-set construction the section below blames — see it for the shape of the
design, but the arithmetic above for where the time actually goes.

**The linear registry did not move this row, and that is the interesting part.** wire-mvc #148 removed six
allocations and 1536 bytes per request from the courier (see *the registry* below). Socketed, the row is
unchanged within noise — but socketed noise here is ±1.6 µs, which cannot resolve six allocations either
way. The in-process pair can, at ~0.05 µs, and it is unambiguous: `courier-headers` − `routed-match`
measures **+0.41 µs before the change and +0.41 µs after**, p50 identical to the hundredth across three
reps of each binary.

So six allocations per request bought **no measurable time**. That is not a disappointment, it is this
phase's thesis holding: allocations here are real and countable, latency is already at parity, and anyone
reaching for allocation work as a *performance* fix is reaching for the wrong thing — the bridge costs
16–47 µs and all of this is fractions of one.

**Vapor's `AsyncMiddleware` costs ~16 µs per middleware, and that is not Vapor's middleware.** A second
one costs another ~14, so it is per-middleware rather than one-off chain construction; the same header
through Vapor's *native* future-based `Middleware` costs +1.25. The ~16 µs is the `async`↔`EventLoopFuture`
bridge in the shim.

### The bridge

| | min | p50 | p99 |
|---|---|---|---|
| Hummingbird | +8.75 | **+16.25** | +19.88 |
| Vapor | +22.71 | **+45.83** | +47.50 |

Mounting a controller through `ServerTransport` costs an order of magnitude more than everything else here
combined — two currency conversions per direction, an unstructured `Task` per request, and a
`ResponseChannel` rendezvous. WireMVC on its own native path costs +0.62 µs at p50 over the bare server.

### Why WireMVC's header mechanism costs more, by design

Hummingbird's `Response` is a struct with `var headers`; Vapor's is a class. Their middleware runs on the
way *out*, receives a fully-built response, and assigns a field — nothing has reached the socket yet.

The proposal hands a handler a **sender**, not a return slot. `HTTPResponse` is constructed and immediately
consumed, so by the time an outer middleware resumes, the head is on the wire. There is no response object
to mutate. A contribution therefore has to be registered on the way in and applied at the moment of
writing, which is the registry plus `ResponseHeaderApplyingSender`.

**This explains the shape, and it turned out not to explain much cost.** The bisection above prices
registering at nothing measurable and draining at +0.04 … +0.08 µs; the bulk of the mechanism is the
`HTTPFields` insertion, which a mutate-the-response design performs too. The indirection is real and
nearly free — what it buys back is that the head can go out as soon as the handler decides it.

So WireMVC pays *construction* where the others pay *mutation* — the cost of the head reaching the socket
as soon as the handler decides it, which is what makes streaming start promptly. A trade, not an
inefficiency.

### Where the time goes — allocations

Counted with a `malloc`/`calloc`/`realloc` interposer (`Tools/allocount.c`), each scenario run once with an
identical request count. The difference between two scenarios, divided by that count, is what the layer
between them allocates per request. Only matched-framing subtractions are shown; the counts are in the
cost table above.

```
layer                                         allocs/req   bytes/req
Hummingbird's own router                             0.0         -34
Vapor's own router                                  20.0        1309
WireMVC's router + tiers, length-framed              3.0         243
WireMVC's router + tiers, chunked                    4.8        1149
the bridge, on Hummingbird                          46.2        6529
the bridge, on Vapor                               105.1       16523
```

**The negative is real, not noise, and not what the row label suggests.** Hummingbird's routed scenario
allocates ~35 fewer *bytes* per request than its routerless one, with an identical allocation *count*. It
reproduces to within a byte across runs (run-to-run spread is ±0.8 bytes/req) and scales with request
count, so it is neither noise nor a one-off startup difference being amortised by the division.

The cause is that no `raw`/`plain` pair differs *only* by a router. A routerless scenario has to match the
route by hand — `EchoResponder` does `path.split(separator: "/")` and builds a `String` — while the routed
one reads `context.parameters.get("value")`, because the router already split the path as part of routing.
So the row is *router + routed handler* minus *routerless + hand-matching handler*: the router is charged
for routing and credited with the hand-matching it makes unnecessary, and here the credit is slightly
larger. Read it as **zero allocations per request, and fewer bytes than the path-matching it replaces** —
not as a router that saves memory.

This affects every row: the hand-matching is ~35 bytes and no allocations, which is immaterial against
Vapor's 20 allocations or the bridge's 46, and material only here where the true cost is zero.

**Chunking is not an allocation cost.** On the bare proposal server it costs 0.1 allocations and 488 bytes
— and ~19 µs at p99. Whatever makes chunked framing slow is writes and parsing, not the allocator, which
is worth knowing because it means allocation counts would never have found this bug.

**Allocation tracks the bridges' cost ordinally, but not proportionally.** Vapor's bridge allocates 2.28×
what Hummingbird's does and costs 2.92× as much wall-clock. An earlier version of this file reported 2.3×
and 2.1× and treated the near-agreement as two independent instruments corroborating each other; that was
partly an artifact of the framing mismatch, and the ratios came apart once it was fixed. The safe claim is
the ordinal one — Vapor's bridge allocates more and costs more, and `OpenAPIVapor` erecting a
`BodyStreamWriter` per response where `OpenAPIHummingbird` takes a `contentLength:` fast path is a
plausible cause with an allocation delta of the right size.

WireMVC's native tiers allocate 3 objects and 243 bytes per request — a fifteenth of the Hummingbird
bridge.

**These rows predate wire-mvc `f9d6e24`**, which took two allocations off `FrozenRouteTrie.resolve` (see
[walking the path](#walking-the-path-rather-than-splitting-it)). The two WireMVC router rows should now be
two lower; they have not been re-taken socketed, because the difference is smaller than that instrument's
spread. The bridge rows are unaffected — the host's router matches there and `resolve` never runs.

### The in-process floor

Driven in process — no socket, no HTTP client, no kernel — WireMVC's whole native path costs:

```
case                      min      p50      p90      p99      max     mean
literal-route             0.38     0.46     0.46     0.58    12.25     0.45
route-only                0.46     0.54     0.58     0.75    26.12     0.54
+parameter                0.46     0.54     0.58     0.71    11.58     0.55
trie-only                 0.71     0.79     0.88     1.00    23.12     0.81
+outcome                  0.71     0.79     0.83     0.92    18.92     0.81
+registry                 0.79     0.88     0.96     1.00    18.00     0.87
+courier                  0.75     0.83     0.92     1.00    24.67     0.84
```

**0.83 µs at p50, 1.00 µs at p99** for the whole path — route lookup, parameter binding, response
construction, the header registry and the context courier. No tier owns a tail because there is no tail
to own; each step is within measurement error of the one before it.

This floor is what made the framing bug findable. For as long as the socketed run said `+20 µs at p99` and
this one said `+1 µs`, one of them was wrong — and an instrument that disagrees with another by twentyfold
is more useful than either number alone. The two now agree: the socketed row reads +1.96 µs at p50 and
+2.54 µs at p99, which is this measurement plus a socket's worth of noise.

### What WireMVC allocates, and whether it needs to

**Ten allocations and 760 bytes per request**, bisected in process. Re-measured 2026-08-30 against
wire-mvc `f9d6e24`; it read twelve and 920 against `1437735`, nine and 756 when this section was first
written, and where each difference went is the interesting part:

```
what                                          allocs/req   bytes/req
literal route, handler does nothing                  0.0          64   ← was 2.0/224; see below
+ binding one {parameter}                           +2.0        +232
+ building and writing the response                 +4.0        +262
+ stating a Content-Length                          +4.0        +258
+ WireMVCOutcome's `[:]` default                    +1.0         +92   ← found here, now fixed
+ ResponseHeaderRegistry (the courier)              +0.0          +0   ← see below; now +0 for real
                                                    10.0         760
```

**The 64 bytes on a row reading zero allocations are the harness's, not the library's.** `allocount.c`'s
`counted_realloc` adds to `bytes` without incrementing `calls`, so the driver's own sample buffer shows up
as bytes with no call behind them. It is the same 64.0 in every case that reaches zero — `literal-route`
and `deep-literal` alike, whatever the path depth — which is what identifies it as a floor rather than a
residue of the code under test. It was inside the old 224 too. Subtract it before quoting a byte figure as
WireMVC's.

Each row is a pair of cases differing in exactly one thing, and every figure reproduces to the allocation
across runs. The method is the *slope* rather than a single total: each case is run at 22,000 and 62,000
requests and the difference divided by 40,000, so process startup cancels and the figure is per-request
without needing a null baseline.

**The four new ones are the framing fix, and they are not `String(Int)`.** `+trie-length-static`, which
builds the length string once at registration, measures identically to `+trie-length`, which builds it per
request — a length like `"1024"` fits Swift's inline string form and never reaches the allocator. All four
are the **field insertion**. That is not WireMVC's number: the `+fields-N` ladder (13 → 16 → 20 → 23) puts
every response header field at 3–4 allocations, which is what `HTTPFields` costs to insert into.

**One of the four looked like the spelling, and it is not — this was tried and refuted.** `routed-match`
states the same length by building `var fields = HTTPFields()` and handing it to
`HTTPResponse(status:headerFields:)`, and costs **3**, where `stateLengthIfAbsent` mutating an
already-constructed response costs **4**. So the typed path was changed to state the length into a local
`HTTPFields` before constructing the response — and measured **identical**, 12 either way.

The reason is the difference between the two cases, not between the two spellings: `routed-match` builds
its fields *fresh*, while `WireMVCOutcome.send` must copy `headerFields` off the outcome, and that copy
costs exactly what the later mutation would have. The allocation moves; it does not go. The change was
reverted and the reasoning left in the source, since it is the kind that will otherwise be proposed again.

**The `[:]` was a defect, not a cost, and is fixed.** `WireMVCOutcome.init` defaulted
`headerFields: HTTPFields = [:]` — a dictionary literal, the exact spelling wire-mvc #129 removed from
`WireMVCResponseHeaders.resolved` after measuring it at one allocation per call. `+outcome-fields` passes
`HTTPFields()` explicitly and differed in nothing else, which is how it was found: 13 against 12. It was
paid by every typed route that does not return header fields, which is most of them. All seven remaining
defaults — six in `Responses.swift`, one in `StreamingResponses.swift` — now spell it `HTTPFields()`, and
`+outcome` measures 12.

**That pair is now the regression guard.** `+outcome` and `+outcome-fields` differ in nothing but the
default, so they should measure *identical*. If `+outcome` ever reads one above `+outcome-fields` again, a
dictionary literal has come back.

**The registry measured zero here for the wrong reason, and has since been measured properly.** It read +1
when this was first written, then 0: in these cases the registry never escapes the handler, so the
optimiser is free to promote it. The honest measurement needs a case where it escapes, and `+courier` and
`courier-headers` are those cases — the courier is exactly where it escapes into the request context.

Measured across two builds of wire-mvc, before and after `ResponseHeaderRegistry` became a `~Copyable`
struct, with the same slope method and two replicates that agreed to the allocation:

| pair | before | after |
|---|---|---|
| `+courier` − `trie-only` | +6.00 allocs, +1536 B | **+0.00, +0 B** |
| `courier-headers` − `routed-match` | +36.00 allocs, +3924 B | **+30.00, +2388 B** |

`trie-only` (48.00) and `routed-match` (66.00) are unchanged between the builds, which is the control.

The `courier-headers` row is the one that rules out the optimiser: that case contributes a field, drains
it and wraps the sender, so the registry is genuinely used, and it saves the *same* 6.00. Six rather than
the one the change predicted, and **why it is six is not attributed** — an extra async frame would not
explain it, since `WireMVCContextHandler` is untouched and the after-figure is zero.

For contrast, **Hummingbird's router adds none** — its routed and routerless scenarios allocate the same.
So these are not the cost of routing as such; they are choices in this implementation. Four look avoidable:

- ~~**The two baseline allocations.**~~ **Done, and the diagnosis held exactly.** This read
  "`FrozenRouteTrie.resolve` does `requestPath.split(separator: "/", omittingEmptySubsequences: true)`,
  materialising an `[Substring]` for every request before walking it — the walk is a single forward pass
  and does not need the array". It now walks the path with a cursor, and the array is gone. Measured below:
  **−2 allocations and −160 bytes on every case that routes**, and −4 on a five-segment one.
- **The two parameter allocations.** Values are collected positionally and then built into a
  `[String: Substring]` via `Dictionary(zip(...))`. Most routes bind nought to two parameters, where a
  small inline buffer would avoid the dictionary entirely, and the handler's lookup by name could resolve
  against the route's own `parameterNames` instead.
- ~~**The registry.**~~ **Done, and better than the suggestion here.** This read "a `final class` the
  courier instantiates per request, whether or not any middleware contributes a header — allocating it
  lazily on first contribution would make the common case free". It is now a `~Copyable` struct that is
  never heap-allocated at all, so *every* case is free, not just the uncontributed one. That was done for
  an ownership reason rather than this one (see wire-mvc's `LinearResponseHeaderRegistry.md`); the six
  allocations are a side payment.
- **The `[:]` default**, which is a one-line fix and the only item here that is a mistake rather than a
  trade.

The remaining four, for building and writing the response, are the least suspicious: producing bytes and
handing them to a sender is the work itself. The four for framing are a trade rather than a waste — they
bought a p99 tail of 12–19 µs on every server tested, which is four orders of magnitude more than four
allocations cost. They are listed because they are countable and were not counted before, not because
they should be given back.

None of this is urgent — the whole path is ~1 µs — but it is the difference between "as cheap as
Hummingbird's router" and "nine allocations cheaper than it looks". The bridge's 46 and 105 are the
numbers that matter; these are the ones that would still be there after the bridge is gone.

Note that the first two do not exist on a *bridged* runtime at all: there the host's router matches the
path and parameters arrive as `metadata.pathParameters`, so `FrozenRouteTrie.resolve` never runs. The two
clearest wins here are native-path-only — which is why the one now taken shows up on every in-process
case below and would not have shown up on a bridged one at all.

#### Walking the path rather than splitting it

wire-mvc `f9d6e24` against its parent `ee9693d`, so the one commit is the only variable. Two release
builds of this harness, `swift package edit wire-mvc --path` at each worktree, the binaries copied out and
run alternately rather than one arm after the other.

Allocations, by the same slope method:

| case | before | after | delta |
|---|---|---|---|
| `deep-literal` (five segments) | 4.000 / 672 B | **0.000 / 64 B** | −4.00, −608 B |
| `literal-route` (two segments) | 2.000 / 224 B | **0.000 / 64 B** | −2.00, −160 B |
| `route-only` | 4.000 / 456 B | 2.000 / 296 B | −2.00, −160 B |
| `+parameter` | 4.000 / 456 B | 2.000 / 296 B | −2.00, −160 B |
| `trie-only` | 8.000 / 718 B | 6.000 / 558 B | −2.00, −160 B |
| `+trie-length` | 12.000 / 976 B | 10.000 / 816 B | −2.00, −160 B |
| `+outcome` | 12.000 / 920 B | 10.000 / 760 B | −2.00, −160 B |
| `routed-match` | 11.000 / 884 B | 9.000 / 724 B | −2.00, −160 B |

**The predicted 2-and-4 is what the before column reads, and both go to zero.** `literal-route`'s
2.0 / 224 reproduced the figure recorded above to the byte before anything was changed, which is the
control that says this instrument is comparable to the run those numbers came from.

**The change also shows up on the clock, which the commit declined to claim.** Three replicates, arms
interleaved, `ROUNDS=6 WARMUP=2000 ITERATIONS=20000`, p50 µs:

| case | before | after | delta |
|---|---|---|---|
| `deep-literal` | 0.50 / 0.46 / 0.46 | 0.38 / 0.38 / 0.38 | **−0.08 … −0.12** |
| `literal-route` | 0.46 / 0.46 / 0.46 | 0.42 / 0.42 / 0.42 | **−0.04** |
| `trie-only` | 0.79 / 0.83 / 0.83 | 0.75 / 0.75 / 0.75 | −0.04 … −0.08 |
| `routed-match` | 0.88 / 0.92 / 0.88 | 0.83 / 0.83 / 0.83 | −0.05 … −0.09 |

No overlap between the arms on any case, and `deep-literal`'s p99 moves 0.75 / 0.62 / 0.67 to
0.54 / 0.50 / 0.50. This is at the edge of what the in-process clock resolves — the quantum is about
0.04 µs — so the evidence is the *separation across replicates*, not any single figure.

**The depth ordering inverts, and that is the claim landing rather than a curiosity.** Before,
`deep-literal` cost at least what `literal-route` did; after, it is the *faster* of the two (0.38 against
0.42). The array growth scaled with segments and the walk scales with characters, and `/a/b/c/d/e` is
shorter than `/echo/benchmark`. A deeper route used to pay more and now pays less.

**Not run socketed, deliberately.** ~0.05 µs against a ~78 µs floor with ±1.6 µs of run-to-run spread is
below what that instrument resolves, so a null result there would have meant nothing and a positive one
would have been noise.

### The ordering problem, and what it invalidated

For most of this harness's life, scenarios were driven **round-robin with every server running at once** —
one request each per pass, in a fixed order. That was itself a fix: measuring scenarios one after another
gives each its own slice of wall-clock, so machine drift lands on whichever was running and is reported as
its cost.

Interleaving fixed drift and introduced two artefacts that were worse for being reproducible.

**Position bias.** A request issued straight after a request to a slow server is itself slower. A fixed
ring means a fixed predecessor, so the handicap is permanent. `proposal-plain` sat behind `vapor-bridged`
(~120 µs) and read 2.6–3.7 µs above `proposal-plain-served` — while the two run *identically* as a pair:

| ring contents | `proposal-plain` | `proposal-plain-served` | spread |
|---|---|---|---|
| the two alone | 76.67 | 76.83 | 0.00 |
| + a slow neighbour ahead of `plain` | 80.33 | 77.71 | **+2.62** |
| + a fast neighbour instead | 76.42 | 76.79 | −0.37 |
| all fifteen | 83.33 | 80.00 | **+3.33** |

Those two scenarios run the **same handler on the same server**, differing only in whether `server.serve`
or `WireMVC.serve` starts it. Their true difference is nothing, which makes them the harness's control —
and it read −2.5 µs on average across twelve consecutive runs.

**Crowding.** Fifteen servers alive at once contend for threads, event loops and cache. The same two
scenarios measure ~76.7 µs as a pair and ~80–83 in a fifteen-scenario ring, so every number was inflated
before any comparison started.

**Rotating the ring does not fix it.** Rotation preserves the cycle — scenario *i* is still preceded by
*i−1*; only the pass boundary moves. That was tried first and measured no better.

The driver now runs **one server at a time** in **six shuffled rounds**. The control:

```
fixed-order ring   −2.25 −2.38 −2.46 −2.46 −2.50 −2.58 −2.62 −2.71 −2.83 −2.87 −3.12 −3.33
isolated, shuffled −0.54 −0.13 −0.71
```

**This invalidated every socketed comparison taken before it.** Under the old driver WireMVC's router read
**−3.21 µs** — a negative cost, reported here as "indistinguishable from Hummingbird's". It is +0.54, and
Hummingbird's is +0.71; the conclusion survives, but it was luck. The in-process numbers were never
affected, and now corroborate rather than contradict the socketed ones — which is the first time in this
harness's history the two instruments have agreed.

Two consequences for reading the tables. **Prefer p50 over min**: restarting servers each round produces
more distinct warm-up states, so minima catch outliers (the control has shown min −11 µs while its p50 sat
at +0.5). And **p99 is noisier than it was**, because each scenario's tail is now sampled in six shorter
bursts; a tail question wants more rounds rather than more iterations.

### The framing bug

`proposal-native` used to sit ~+11 µs at the minimum and ~+20 µs at p99 above the bare handler over a
socket, while measuring 1.00 µs at p99 in process. Three explanations were tested and all were wrong:

- **Scenario ordering** — refuted by interleaving; the delta survived.
- **A layer the bisection skipped** — refuted by measuring `WireMVCContextHandler` directly; it costs one
  allocation and no measurable time.
- **The serving path** (`WireMVC.serve` under ServiceLifecycle versus `NIOHTTPServer.serve` directly) —
  refuted by `proposal-plain-served`, which runs the *bare* handler through `WireMVC.serve` and matches
  the bare floor.

All three asked *which layer of WireMVC contains the cost*. None of them was going to find it, because the
cost was not in a layer — it was in the bytes leaving the process. WireMVC never set `Content-Length`.
`WireMVCOutcome.send` held the encoded body, and therefore its length, and sent
`HTTPResponse(status:headerFields:)` with whatever the caller had put in `headerFields`. Nothing
downstream infers a length either — `NIOHTTPServer`'s only `Content-Length` is the one it writes for an
aborted request — so every WireMVC response on every runtime went out `Transfer-Encoding: chunked`, while
every non-WireMVC scenario here was framed by length.

Found by dumping the response headers of all nine scenarios (`PROBE=1`), which took about a minute and
had never been done, because framing was something the harness set once in a hand-written handler and
never varied. The three non-WireMVC scenarios all sent `Content-Length: 14`; the three WireMVC ones all
sent `transfer-encoding: chunked`.

The sharper statement, once every scenario could be run either way: chunking is not WireMVC's cost at all.
Frame both sides alike and WireMVC's delta is ~2 µs either way — +1.96 µs at p50 length-framed, +1.79 µs
chunked. Frame them differently and WireMVC appears to cost 20 µs at p99. The whole apparent tail was the
mismatch, and **every** bare server here pays a p99 tail for chunked framing with no WireMVC in it at all:
+11.8 µs on Hummingbird, +14.3 µs on Vapor, +18.9 µs on the proposal server.

That is why the three refuted hypotheses refuted correctly and taught nothing: there was no cost in any
layer to find.

Two things are worth keeping from this. **Framing is not a detail of the harness; it is part of what a
server does**, and a benchmark that holds it constant for some scenarios and not others is comparing two
things at once. **And a component's cost cannot be measured only through an instrument larger than it** —
but the disagreement between a large instrument and a small one is itself a measurement, and here it was
the only thing pointing at a real defect. The in-process pass did not find the bug; the *contradiction*
did.

The fix is in WireMVC (`WireMVCOutcome.send` now states the length it holds, subject to RFC 9110 §8.6's
exclusions for `1xx`, `204` and `304`). `FRAMING=chunked` reproduces the old behaviour for comparison.

Note what the fix does *not* cover: a **raw** route registered by hand does not go through
`WireMVCOutcome`, so it states its own length or gets chunked. The scenarios here are raw routes, and set
the header themselves — which is why they model the typed tiers rather than being them.

## Methodology

**Every scenario is driven identically.** One `AsyncHTTPClient`, pinned to HTTP/1.1, over a real loopback
socket, against a server bound to an ephemeral port. The client, the socket, the request and the response
bytes are constants; what varies is the stack a request traverses inside the server.

**Every scenario serves the same route** — `GET /echo/{value}`, echoing the bound parameter into a small
body (`SharedRoute.swift`). The handler is as close to nothing as a route can be while still binding a
parameter and writing a body, so the measurement is of the framework around it.

**Each framework is compared to itself.** This is the point of the eight scenarios rather than three.
Note the *two* floors per framework: a routerless one and a routed one. Without the routerless pair,
"plain Hummingbird" silently includes Hummingbird's router while the proposal baseline includes none, so
the floors are not the same floor and the frameworks' routers cannot be priced at all.

| | serves | isolates |
|---|---|---|
| `hummingbird-raw` | a bare `HTTPResponder`, no router | Hummingbird's server alone |
| `hummingbird-plain` | a plain Hummingbird route | Hummingbird's server **+ its router** |
| `hummingbird-bridged` | the same route through `WireMVCServerTransport` | WireMVC **+ the bridge** |
| `vapor-raw` | a `Responder` installed directly, no routing | Vapor's server alone |
| `vapor-plain` | a plain Vapor route | Vapor's server **+ its router** |
| `vapor-bridged` | the same route through `WireMVCServerTransport` | WireMVC **+ the bridge** |
| `proposal-plain` | a hand-written handler via `NIOHTTPServer.serve` | the proposal server's floor |
| `proposal-plain-served` | the same handler via `WireMVC.serve` | the **serving path** alone |
| `proposal-routed` | WireMVC's trie on the bare server, no courier | WireMVC's **router alone**, scope-matched to the `plain` rows |
| `proposal-native` | the same route through WireMVC's own router | WireMVC **alone** |

Subtracting each framework's bare scenario from its WireMVC scenario cancels the HTTP server out.
Comparing *across* frameworks would not isolate anything — the three bare servers span ~5 µs before WireMVC
is involved at all, which the harness prints separately so it is not mistaken for signal.

**Reported as a distribution, not a mean.** Every request's latency is kept, not per-round averages — the
framing bug showed up first as a fat p99 and would have been invisible in a round mean. Read **p50** as the
primary figure: under the isolated driver each round restarts its server, which gives minima more distinct
warm-up states to catch, so the minimum is no longer the steadiest column.

**Each scenario runs alone, in shuffled rounds.** One server alive at a time, six rounds, a different
order each round. Running them concurrently in a fixed ring inflates every number and gives each scenario a
permanent handicap from whatever precedes it — see [the ordering
problem](#the-ordering-problem-and-what-it-invalidated). `SEQUENTIAL=1` restores one-long-slice-per-scenario,
for reproducing the drift artefact that interleaving originally existed to avoid.

**Framing is held constant.** Every scenario states a `Content-Length`. This has to be deliberate: a
scenario that omits it is chunked, and is then being compared with length-framed ones on more than the
axis being studied. `FRAMING=chunked` varies it on purpose.

### What this does not measure

- **Anything at the scale of WireMVC's own path.** The socketed numbers carry ~60 µs of client and kernel
  with a tail of its own; a ~1 µs component is at the edge of what it can resolve. Use the
  in-process pass at that scale — and treat a disagreement between the two as a finding rather than as
  noise, which is how the framing bug surfaced.
- **Concurrency.** Requests are issued sequentially, so this is latency under no contention. The bridge's
  per-request `Task` may cost differently under load, in either direction.
- **Why one bridge is dearer than the other.** Both are measured, and the allocation counts bound the
  answer, but the attribution to `OpenAPIVapor`'s body construction is still a hypothesis: the counter
  gives totals, and naming individual allocations needs a profiler.
- **Why chunked framing is slow.** It is measured on all three servers and shown not to be allocation, but
  separating extra writes from client-side chunk parsing would need instrumentation on both ends. Note
  also that only the proposal server is chunked by omitting a header; Hummingbird's and Vapor's chunked
  rows use a streamed body, so their p50 includes streaming machinery that the framing question does not.
- **A router in isolation.** No `raw`/`plain` pair differs only by a router: the routerless scenario must
  match the route by hand, so each row is a router *net of* the hand-matching it replaces. Worth ~35 bytes
  and no allocations — see the note in the allocation section.
- **Real handlers.** See the caveat above about ratios.

## Reproducing

Requires the toolchain in `.swift-version` (WireMVC is proposal-native, which sets a Swift 6.4 floor):

```sh
swiftly run swift run -c release
```

**Release builds only.** A debug build measures the optimiser's absence, not the framework.

**Update the pin first.** `Package.resolved` is not committed and `wire-mvc` is tracked by branch, so a
checkout keeps whatever revision it first resolved — indefinitely. This harness silently measured a
three-commit-stale library for a whole afternoon, and only gave itself away when a scenario contradicted a
fix that had already merged. Before trusting any number:

```sh
swiftly run swift package update wire-mvc
```

And if you have been iterating on the library locally with `swift package edit`, `swift package unedit
wire-mvc` before quoting anything as reflecting merged main — an edited checkout reads your working tree.

**`swift-wire` has to move with it.** wire-mvc's route codegen and swift-wire's `@Scoped` machinery are
versioned together, so updating one alone fails in *generated* code rather than anywhere you would think to
look — `_WireRoutes.swift: value of tuple type '(…Controller, … () async -> [any Error])' has no member
'_wireSubject'` is a swift-wire that is behind, not a broken plugin. `swift package update swift-wire`
alongside the line above.

**To A/B two revisions of the library**, `swift package edit wire-mvc --path <worktree>` at each in turn,
build `-c release`, and copy the binary out of `--show-bin-path` before uneditting. The copies run from
anywhere, so the two arms can be *interleaved* rather than measured one after the other — which matters
here for the same reason the shuffled rounds do.

Knobs, all environment variables:

```sh
ITERATIONS=20000 WARMUP=2000 ROUNDS=6 swiftly run swift run -c release   # the defaults
SCENARIOS=proposal-plain,proposal-native swiftly run swift run -c release  # a subset
SCENARIOS=none swiftly run swift run -c release          # the in-process pass alone
SKIP_INPROCESS=1 swiftly run swift run -c release        # the socketed scenarios alone
SEQUENTIAL=1 swiftly run swift run -c release            # one long slice each, the drift artefact
FRAMING=chunked swiftly run swift run -c release         # omit Content-Length, as WireMVC once did
PROBE=1 swiftly run swift run -c release                 # print each scenario's response headers and exit
```

`PROBE=1` is the cheapest check in the harness and the one that found the largest error in it. Run it
after any change to how a scenario responds.

Allocation counts, per scenario:

```sh
clang -dynamiclib -O2 -o /tmp/allocount.dylib Tools/allocount.c
BIN=$(swiftly run swift build -c release --show-bin-path)
DYLD_INSERT_LIBRARIES=/tmp/allocount.dylib SCENARIOS=vapor-bridged ITERATIONS=20000 \
  "$BIN/wire-mvc-performance"          # prints ALLOCATIONS <calls> <bytes> at exit
```

Run two scenarios with the same `ITERATIONS` and `WARMUP` and subtract; divide by the total request count
(iterations + warmup). The counts are process-wide, so only differences mean anything.

`ITERATIONS` is the total per scenario and `ROUNDS` is how many slices it is split into. Rounds are what
average drift out under the isolated driver, so raising them costs nothing and tightens the control: six
measurably beat three, three beat one.

Expect the absolute numbers to move with machine, kernel and toolchain. The *differences* between
scenarios are what the harness is for, and they should be stable across runs on one machine — if `best`
and `median` diverge much, the machine was busy and the run should be repeated.

## A gotcha this harness ran into, worth knowing

A hand-written route handler that **never reads the request** leaves it unfinished, and
`HTTPKeepAliveHandler` closes the connection once the response ends. The symptom is that the *second*
request on a pooled connection fails with `I/O on closed channel`, while `curl` — which the harness was
first debugged with — appears to work, because a single request never reuses a connection.

Both hand-written handlers here drain the reader for that reason. A real WireMVC route does not have to:
its typed terminal collects the body. This only bites code that registers a route by hand.

## Layout

```
Sources/WireMVCPerformance/
  main.swift            # the driver: start a scenario, wait for its port, time it, report
  Scenarios.swift       # the Hummingbird and proposal-server scenarios
  VaporScenarios.swift  # Vapor's — a separate file because Hummingbird and Vapor both define
                        # Application, Request and Response
  SharedRoute.swift     # the one route they all serve, and the hand-written RouteContributor
  InProcess.swift       # the in-process bisection: no socket, no client, no kernel
Tools/allocount.c       # a malloc/calloc/realloc interposer, for per-request allocation counts
```
