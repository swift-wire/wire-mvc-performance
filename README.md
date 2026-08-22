# wire-mvc-performance

A benchmark harness isolating **where WireMVC's per-request cost goes** — its own tiers, the HTTP server
under it, or the `ServerTransport` bridge that mounts it on Hummingbird and Vapor.

It exists because the question kept being argued rather than measured, and because the first attempts to
measure it produced two contradictory answers. Both were wrong for the same reason: they compared numbers
taken with *different harnesses*.

## Results

Two dimensions, not one: **the layer a request traverses**, and **how the response is framed**. Framing is
here rather than in a footnote because holding it constant for some scenarios and not others produced the
largest error this harness has made — see [the framing bug](#the-framing-bug).

Every scenario can now be run either way, so both columns are internally matched: a delta always subtracts
two scenarios framed alike. One caveat carries throughout. The proposal server is chunked by *omitting*
`Content-Length`; Hummingbird and Vapor derive a length from a `ByteBuffer` body, so there is no header to
omit and their chunked rows use a **streamed body** instead. That is a different code path, not the same
one framed differently, and their chunked p50 carries the streaming machinery as well as the framing.

### Layer 0 — the servers themselves

Routerless. The floor every framework sits on, and the reason each framework is compared to *itself*.

| server | framing | min | p50 | p90 | p99 |
|---|---|---|---|---|---|
| `hummingbird-raw` | length | 59.17 | 76.21 | 84.08 | 97.75 |
| `hummingbird-raw` | chunked | 60.46 | 83.25 | 91.33 | **109.50** |
| `vapor-raw` | length | 52.00 | 71.12 | 77.92 | 88.79 |
| `vapor-raw` | chunked | 63.42 | 76.38 | 84.33 | **103.12** |
| `proposal-plain` | length | 59.12 | 82.08 | 89.42 | 102.58 |
| `proposal-plain` | chunked | 68.62 | 83.21 | 107.58 | **121.46** |

**Chunking costs a p99 tail on every server, with no framework and no router involved**: +11.8 µs on
Hummingbird, +14.3 µs on Vapor, +18.9 µs on the proposal server. So the tail is a property of chunked
framing on this stack — NIO's encoder and `AsyncHTTPClient`'s decoder — and not of any one server.

The medians separate the two effects. The proposal server, where chunked really is just the missing
header, moves +1.1 µs at p50 but +18.2 µs at p90; the tail is nearly the whole cost. Hummingbird and
Vapor move +7.0 and +5.3 µs at p50, because their chunked rows also pay for a streamed body. The tail
survives in all three regardless.

### Layer 1 — with a router

#### Length-framed — what ships today

| scenario | min | p50 | p90 | p99 |
|---|---|---|---|---|
| `hummingbird-plain` | 59.79 | 76.00 | 84.62 | 98.71 |
| `hummingbird-bridged` | 69.42 | 92.33 | 99.96 | 115.83 |
| `vapor-plain` | 54.33 | 75.17 | 81.79 | 92.79 |
| `vapor-bridged` | 90.29 | 122.83 | 130.58 | 148.96 |
| `proposal-plain-served` | 59.58 | 79.62 | 87.00 | 100.33 |
| `proposal-native` | 59.54 | 81.58 | 89.54 | 102.88 |

#### Chunked — what WireMVC shipped before the fix

| scenario | min | p50 | p90 | p99 |
|---|---|---|---|---|
| `hummingbird-plain` | 62.00 | 84.04 | 92.29 | 110.38 |
| `hummingbird-bridged` | 80.46 | 107.29 | 116.92 | 132.92 |
| `vapor-plain` | 63.50 | 80.46 | 88.17 | 107.08 |
| `vapor-bridged` | 105.12 | 148.00 | 156.08 | 176.92 |
| `proposal-plain-served` | 68.62 | 81.33 | 103.67 | 118.79 |
| `proposal-native` | 70.04 | 83.12 | 106.71 | 121.58 |

### What each layer costs

Each figure subtracts a framework's own bare server from itself-plus-a-layer, which cancels the HTTP
server out. Both sides of every subtraction share a framing.

| layer | length p50 | length p99 | chunked p50 | chunked p99 | allocs/req |
|---|---|---|---|---|---|
| Hummingbird's own router | −0.21 | +0.96 | +0.79 | +0.88 | 0.0 |
| Vapor's own router | +4.04 | +4.00 | +4.08 | +3.96 | 20.0 |
| WireMVC's own router + tiers | +1.96 | +2.54 | +1.79 | +2.79 | 3.0 |
| WireMVC through the bridge, Hummingbird | **+16.33** | +17.13 | +23.25 | +22.54 | 46.2 |
| WireMVC through the bridge, Vapor | **+47.67** | +56.17 | +67.54 | +69.83 | 105.1 |

Allocation counts are the length-framed ones.

### What it adds up to

- **WireMVC's own path costs ~2 µs, and the same ~2 µs under either framing.** That is the whole point of
  the chunked column: WireMVC is not what chunking costs. It merely omitted the header that avoided it,
  and then appeared to cost 20 µs because it was being compared against something length-framed.
- **The bridge is the expense**: +16.33 µs on Hummingbird and +47.67 µs on Vapor, 8× and 24× the native
  path. It is also where chunking hurts most — the bridge's chunked cost rises to +23.25 and +67.54, so
  the bridge amplifies framing cost rather than merely passing it through.
- **The routers agree with themselves across framings** (Hummingbird ~0, Vapor ~+4 µs at both p50s),
  which is the check that the two columns are measuring what they claim to.

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

Nine allocations and 756 bytes per request, bisected in process:

```
what                                          allocs/req   bytes/req
literal route, handler does nothing                  2.0         226
+ binding one {parameter}                           +2.0        +232
+ building and writing the response                 +4.0        +262
+ ResponseHeaderRegistry (the courier)              +1.0         +36
                                                     9.0         756
```

For contrast, **Hummingbird's router adds none** — its routed and routerless scenarios allocate the same.
So these are not the cost of routing as such; they are choices in this implementation. Three look avoidable:

- **The two baseline allocations.** `FrozenRouteTrie.resolve` does
  `requestPath.split(separator: "/", omittingEmptySubsequences: true)`, materialising an `[Substring]` for
  every request before walking it. The walk is a single forward pass and does not need the array — it
  could iterate segments lazily. This is the clearest candidate, and it costs even routes with no
  parameters.
- **The two parameter allocations.** Values are collected positionally and then built into a
  `[String: Substring]` via `Dictionary(zip(...))`. Most routes bind nought to two parameters, where a
  small inline buffer would avoid the dictionary entirely, and the handler's lookup by name could resolve
  against the route's own `parameterNames` instead.
- **The registry.** `ResponseHeaderRegistry` is a `final class` the courier instantiates per request,
  whether or not any middleware contributes a header. Allocating it lazily on first contribution would
  make the common case free.

The remaining four, for building and writing the response, are the least suspicious: producing bytes and
handing them to a sender is the work itself.

None of this is urgent — the whole path is ~1 µs — but it is the difference between "as cheap as
Hummingbird's router" and "nine allocations cheaper than it looks". The bridge's 46 and 105 are the
numbers that matter; these are the ones that would still be there after the bridge is gone.

Note that the first two do not exist on a *bridged* runtime at all: there the host's router matches the
path and parameters arrive as `metadata.pathParameters`, so `FrozenRouteTrie.resolve` never runs. The two
clearest wins here are native-path-only.

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
| `proposal-native` | the same route through WireMVC's own router | WireMVC **alone** |

Subtracting each framework's bare scenario from its WireMVC scenario cancels the HTTP server out.
Comparing *across* frameworks would not isolate anything — the three bare servers span ~5 µs before WireMVC
is involved at all, which the harness prints separately so it is not mistaken for signal.

**Reported as a distribution, not a mean.** Benchmark noise is one-sided: scheduling, page faults and
GC-like effects only ever make a request slower, so the minimum is the closest estimate of the cost itself
and the percentiles say how often something else happened. A mean hides both. Every request's latency is
kept, not per-round averages — the framing bug showed up first as a fat p99 and would have been invisible
in a round mean.

**Scenarios are interleaved, not run in sequence.** One pass of the ring per iteration, so consecutive
samples of different scenarios are adjacent in time and machine state cannot drift between them and be
attributed to a scenario. `SEQUENTIAL=1` restores the old behaviour.

**Framing is held constant.** Every scenario states a `Content-Length`. This has to be deliberate: a
scenario that omits it is chunked, and is then being compared with length-framed ones on more than the
axis being studied. `FRAMING=chunked` varies it on purpose.

### What this does not measure

- **Anything at the scale of WireMVC's own path.** The socketed numbers carry ~60 µs of client and kernel
  with a tail of its own; a ~1 µs component cannot be resolved through it, interleaved or not. Use the
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

Knobs, all environment variables:

```sh
ITERATIONS=20000 WARMUP=2000 ROUNDS=3 swiftly run swift run -c release   # the defaults
SCENARIOS=proposal-plain,proposal-native swiftly run swift run -c release  # a subset
SCENARIOS=none swiftly run swift run -c release          # the in-process pass alone
SKIP_INPROCESS=1 swiftly run swift run -c release        # the socketed scenarios alone
SEQUENTIAL=1 swiftly run swift run -c release            # no interleaving, for reproducing that artefact
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
