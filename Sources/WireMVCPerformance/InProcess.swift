import BasicContainers
import HTTPAPIs
import HTTPTypes
import WireMVC
import WireMVCRouter

// Driving the router **in process** — no socket, no HTTP client, no kernel.
//
// The socketed scenarios spend ~60 of their ~77 µs in `AsyncHTTPClient` and loopback TCP, and that noise
// has a tail of its own: a bare Hummingbird responder showed a 929 µs max in one run. Reading a ~20 µs
// tail through that is reading a small signal through a larger, similarly-shaped one.
//
// Here the only thing between the clock and the router is a request context, a reader and a sender that do
// nothing. Whatever tail survives is the router's.

/// A request context with no capabilities — the proposal's minimum.
struct BenchRequestContext: HTTPServerCapability.RequestContext {
    init() {}
}

/// An `AsyncReader` over an empty body, delivering end-of-stream in the first read.
struct BenchReader: AsyncReader {
    typealias ReadElement = UInt8
    typealias ReadFailure = Never
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        do {
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// A sender that discards. Deliberately *not* a rendezvous: `WireMVCTesting`'s in-process writer suspends
/// until a consumer receives each chunk, which is right for testing backpressure and wrong for measuring a
/// floor — it would put a scheduler hop into the thing being measured.
struct BenchResponseSender: HTTPResponseSender {
    typealias Writer = BenchWriter

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> BenchWriter {
        BenchWriter()
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {}
}

struct BenchWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {}

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {}
}

/// A router whose context is the **courier's**, wrapped in `WireMVCContextHandler` — the shape the
/// proposal-native scenario actually serves.
///
/// The bisection above drives `FrozenTrieRouter` with a plain context, which skips this layer entirely:
/// `WireMVCContextServer` builds a `WireMVCContext` and a `ResponseHeaderRegistry` per request *before*
/// the router sees it. Measuring the router without it measured most of the path and called it all of it.
func courierRouter() -> some HTTPServerRequestHandler<BenchRequestContext, BenchReader, BenchResponseSender> {
    var builder = TrieRouteBuilder<
        WireMVCContext<BenchRequestContext>, BenchReader, BenchResponseSender
    >()
    builder.register(method: .get, path: SharedRoute.path) { _, _, parameters, _, responseSender in
        let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
        var body = UniqueArray<UInt8>(copying: SharedRoute.body(for: value))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
    return WireMVCContextHandler(inner: builder.finalize())
}

/// **The in-process match for `proposal-headers`**: the courier on top, a route that contributes a header
/// and wraps its sender, and a handler that states its own length.
///
/// Every difference from ``courierRouter()`` is one the socketed scenario also has, and every difference
/// from the `routed-match` case below is one `proposal-headers` has over `proposal-routed`. The point is a
/// delta measurable at ~0.05 µs that can be compared against the socketed delta directly: socketed the
/// mechanism reads ~3 µs and the older, *unmatched* in-process cases read ~0.75, and one of those is wrong.
func courierHeadersRouter() -> some HTTPServerRequestHandler<
    BenchRequestContext, BenchReader, BenchResponseSender
> {
    var builder = TrieRouteBuilder<
        WireMVCContext<BenchRequestContext>, BenchReader, BenchResponseSender
    >()
    builder.register(method: .get, path: SharedRoute.path) { _, context, parameters, _, responseSender in
        let contents = context.takeContents()
        var registry = contents.responseHeaders.take()
        registry.add(.set(staticHeaderName, SharedHeader.value))
        let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
        let bytes = SharedRoute.body(for: value)
        var fields = HTTPFields()
        fields[.contentLength] = String(bytes.count)
        var body = UniqueArray<UInt8>(copying: bytes)
        let applying = ResponseHeaderApplyingSender(wrapping: responseSender, registry: registry)
        // The **two-argument** spelling, matching `proposal-headers` and matching what a hand-written raw
        // route writes. It binds to the proposal's extension and so goes `send` → the deferred-head writer
        // → `finish`, where the three-argument spelling would reach the wrapper's own witness and skip that
        // writer entirely. Two different paths through the same type; this is the one raw routes take.
        try await applying.sendAndFinish(
            HTTPResponse(status: .ok, headerFields: fields),
            buffer: &body
        )
    }
    return WireMVCContextHandler(inner: builder.finalize())
}

/// **The typed tier's header mechanism**, which is a different mechanism from the raw one above.
///
/// A `@Controller` route never meets `ResponseHeaderApplyingSender` — codegen only wraps the sender for
/// `@RawRoute`. Its terminal drains the registry itself and hands the fields to a `WireMVCOutcome`:
///
///     headerFields: WireMVCResponseHeaders.resolved(middleware: try await drain.drain())
///
/// So it uses the array-returning `drain()`, not `drain(into:)`, and `resolved` rather than applying onto
/// a head. `contributing` toggles the contribution so the pair's difference is the mechanism.
func typedRouter(contributingAHeader: Bool) -> some HTTPServerRequestHandler<
    BenchRequestContext, BenchReader, BenchResponseSender
> {
    var builder = TrieRouteBuilder<
        WireMVCContext<BenchRequestContext>, BenchReader, BenchResponseSender
    >()
    builder.register(method: .get, path: SharedRoute.path) { _, context, parameters, _, responseSender in
        let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
        let body = SharedRoute.body(for: value)
        guard contributingAHeader else {
            try await WireMVCOutcome(status: .ok, body: body).send(on: responseSender)
            return
        }
        let contents = context.takeContents()
        var registry = contents.responseHeaders.take()
        registry.add(.set(staticHeaderName, SharedHeader.value))
        let fields = WireMVCResponseHeaders.resolved(middleware: try await registry.drain())
        try await WireMVCOutcome(status: .ok, headerFields: fields, body: body).send(on: responseSender)
    }
    return WireMVCContextHandler(inner: builder.finalize())
}

/// Drive a courier-wrapped router, returning each request's latency in microseconds.
func driveCourier<Handler: HTTPServerRequestHandler>(
    _ handler: Handler,
    warmup: Int,
    iterations: Int
) async throws -> [Double]
where
    Handler.RequestContext == BenchRequestContext,
    Handler.Reader == BenchReader,
    Handler.ResponseSender == BenchResponseSender
{
    let request = HTTPRequest(method: .get, scheme: "http", authority: "bench", path: "/echo/benchmark")

    func once() async throws {
        try await handler.handle(
            request: request,
            requestContext: BenchRequestContext(),
            reader: BenchReader(),
            responseSender: BenchResponseSender()
        )
    }

    for _ in 0..<warmup { try await once() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = ContinuousClock.now
        try await once()
        samples.append(micros(since: start))
    }
    return samples
}

/// A field name built once, so a case that uses it is not also measuring `HTTPField.Name`'s validation of
/// the string on every request.
let staticHeaderName = HTTPField.Name(SharedHeader.name)!

/// One in-process case: a name, and a router built from a route registered some particular way.
struct InProcessCase: Sendable {
    let name: String
    let detail: String
    let make: @Sendable () throws -> FrozenTrieRouter<BenchRequestContext, BenchReader, BenchResponseSender>
}

/// Drive one case directly, returning every request's latency in microseconds.
func driveInProcess(_ subject: InProcessCase, warmup: Int, iterations: Int) async throws -> [Double] {
    let router = try subject.make()
    let path = subject.name == "deep-literal" ? "/a/b/c/d/e" : "/echo/benchmark"
    let request = HTTPRequest(method: .get, scheme: "http", authority: "bench", path: path)

    func once() async throws {
        try await router.handle(
            request: request,
            requestContext: BenchRequestContext(),
            reader: BenchReader(),
            responseSender: BenchResponseSender()
        )
    }

    for _ in 0..<warmup { try await once() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = ContinuousClock.now
        try await once()
        samples.append(micros(since: start))
    }
    return samples
}

// MARK: - The tiers, bisected

// `proposal-native` in the socketed run registers a **raw closure** on the trie — so what it measures over
// `proposal-plain` is the context courier and the trie lookup, *not* the typed tiers. These cases add one
// layer at a time so a tail can be attributed to the layer that introduces it.

/// A router with `build` registered at `/echo/{value}`.
private func router(
    _ build:
        @escaping @Sendable (
            HTTPRequest, consuming BenchRequestContext, [String: Substring], consuming sending BenchReader,
            consuming sending BenchResponseSender
        ) async throws -> Void
) -> FrozenTrieRouter<BenchRequestContext, BenchReader, BenchResponseSender> {
    var builder = TrieRouteBuilder<BenchRequestContext, BenchReader, BenchResponseSender>()
    builder.register(method: .get, path: SharedRoute.path, handler: build)
    return builder.finalize()
}

let inProcessCases: [InProcessCase] = [
    InProcessCase(
        name: "deep-literal",
        detail: "a five-segment literal route — does cost scale with depth?"
    ) {
        var builder = TrieRouteBuilder<BenchRequestContext, BenchReader, BenchResponseSender>()
        builder.register(method: .get, path: "/a/b/c/d/e") { _, _, _, _, _ in }
        return builder.finalize()
    },
    InProcessCase(
        name: "literal-route",
        detail: "a route with no {parameter} at all, handler does nothing"
    ) {
        var builder = TrieRouteBuilder<BenchRequestContext, BenchReader, BenchResponseSender>()
        builder.register(method: .get, path: "/echo/benchmark") { _, _, _, _, _ in }
        return builder.finalize()
    },
    InProcessCase(
        name: "route-only",
        detail: "resolve and dispatch, handler does nothing"
    ) {
        router { _, _, _, _, _ in }
    },
    InProcessCase(
        name: "+parameter",
        detail: "resolve, dispatch, and read the bound parameter"
    ) {
        router { _, _, parameters, _, _ in
            _ = parameters[SharedRoute.template].map(String.init)
        }
    },
    InProcessCase(
        name: "trie-only",
        detail: "route lookup, handler writes the response itself"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var body = UniqueArray<UInt8>(copying: SharedRoute.body(for: value))
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    },
    InProcessCase(
        name: "+outcome",
        detail: "response built as a WireMVCOutcome and sent"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            try await WireMVCOutcome(status: .ok, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // Does *stating a length* cost anything? `trie-only` writes a bare `HTTPResponse(status:)`; this is the
    // same handler with the `Content-Length` every WireMVC response has carried since the framing fix, set
    // the way `stateLengthIfAbsent` sets it. The pair differs in nothing else — same spelling of
    // `sendAndFinish`, same body — so the gap is the framing and only the framing.
    InProcessCase(
        name: "+trie-length",
        detail: "the same, stating a Content-Length"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            try await responseSender.sendAndFinish(response, buffer: &body)
        }
    },
    // Is the framing cost the `String(length)` or the field insertion? `stateLengthIfAbsent` spells it
    // `headerFields[.contentLength] = String(length)`, so the two are paid together. Here the body is a
    // fixed size, so the length string can be built once at registration — the gap against `+trie-length`
    // is `String(Int)` and nothing else.
    InProcessCase(
        name: "+trie-length-static",
        detail: "the same, with the length string built once"
    ) {
        let length = String(SharedRoute.body(for: "benchmark").count)
        return router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentLength] = length
            var body = UniqueArray<UInt8>(copying: bytes)
            try await responseSender.sendAndFinish(response, buffer: &body)
        }
    },
    // `WireMVCOutcome.init` defaults `headerFields` to `[:]`, which is a dictionary literal — the spelling
    // #129 removed from `WireMVCResponseHeaders.resolved` after measuring it at one allocation per call.
    // This case passes `HTTPFields()` explicitly and differs from `+outcome` in nothing else, so the gap
    // is that default and only that default.
    InProcessCase(
        name: "+outcome-fields",
        detail: "the same outcome, with an explicit empty HTTPFields"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            try await WireMVCOutcome(
                status: .ok, headerFields: HTTPFields(), body: SharedRoute.body(for: value)
            ).send(on: responseSender)
        }
    },
    InProcessCase(
        name: "+registry",
        detail: "outcome, with a response-header registry drained into it"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            let fields = WireMVCResponseHeaders.resolved(middleware: try await registry.drain())
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The registry's own two calls, bisected. `add` is variadic, so each call builds an Array for the
    // parameter, wraps it in a `.values` case and appends that to `registrations`; `drain` then builds a
    // third array to collect into. These separate allocating the registry, registering into it, and
    // draining it — with `withExtendedLifetime` so a registry that is never read is not optimised away.
    InProcessCase(
        name: "+reg-alloc",
        detail: "a registry allocated and never used"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            try await WireMVCOutcome(status: .ok, body: SharedRoute.body(for: value))
                .send(on: responseSender)
            // Synchronous, and after the send: `withExtendedLifetime` takes no async closure, and the
            // point is only to stop a registry nothing reads from being optimised away.
            withExtendedLifetime(registry) {}
        }
    },
    InProcessCase(
        name: "+reg-add",
        detail: "one contribution registered, never drained"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            try await WireMVCOutcome(status: .ok, body: SharedRoute.body(for: value))
                .send(on: responseSender)
            // Synchronous, and after the send: `withExtendedLifetime` takes no async closure, and the
            // point is only to stop a registry nothing reads from being optimised away.
            withExtendedLifetime(registry) {}
        }
    },
    // Drain with one contribution, discarding it: `add` + the `async` drain, without resolving.
    InProcessCase(
        name: "+drain-only",
        detail: "one contribution, drained and discarded"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            _ = try await registry.drain()
            try await WireMVCOutcome(status: .ok, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The same, now resolving the drained contribution into fields. The field name is a **static** here;
    // the next case builds it per request, which is the difference between the two.
    InProcessCase(
        name: "+resolve",
        detail: "the contribution resolved into fields, static field name"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            let fields = WireMVCResponseHeaders.resolved(middleware: try await registry.drain())
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The same resolution, but writing each contribution with the **scalar** subscript instead of the
    // array-valued one. `WireMVCResponseHeaders.apply` spells a `.set` as `fields[values: name] = [value]`,
    // which builds an `Array` for a single value; `.setIfAbsent` builds one just to ask `.isEmpty`. If that
    // is where the resolve cost is, this case is cheaper by exactly that much.
    InProcessCase(
        name: "+resolve-scalar",
        detail: "the same resolution via the scalar HTTPFields subscript"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            var fields = HTTPFields()
            for contribution in try await registry.drain() {
                switch contribution {
                case let .set(name, value): fields[name] = value
                case let .append(name, value): fields.append(HTTPField(name: name, value: value))
                case let .setIfAbsent(name, value): if fields[name] == nil { fields[name] = value }
                }
            }
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // `WireMVCResponseHeaders.apply` directly, without `resolved`'s wrapper around it. Sits between
    // `+resolve` (the wrapper) and `+resolve-scalar` (a hand-rolled switch), so the two gaps separate what
    // `apply` costs from what the wrapper costs.
    InProcessCase(
        name: "+apply-direct",
        detail: "the library's apply, without resolved's wrapper"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            var fields = HTTPFields()
            for contribution in try await registry.drain() {
                WireMVCResponseHeaders.apply(contribution, to: &fields)
            }
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The same, with a handler that writes **its own header fields** — a content type and a length, as any
    // real raw route does. `+applying` writes a bare `HTTPResponse(status:)`, so it never exercises the
    // path where the handler's fields have to survive alongside the contributions. That is the case where
    // building a fresh `HTTPFields` and replaying the handler's fields into it costs something.
    InProcessCase(
        name: "+applying-fields",
        detail: "the applying sender, handler writing its own fields"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            let bytes = SharedRoute.body(for: value)
            var fields = HTTPFields()
            fields[.contentType] = "text/plain"
            fields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            let applying = ResponseHeaderApplyingSender(wrapping: responseSender, registry: registry)
            try await applying.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body
            )
        }
    },
    /// **The in-process match for `proposal-routed`**: the trie with no courier, a handler that states its
    /// own length and sends. `courier-headers` minus this is the header mechanism, scope-matched.
    InProcessCase(name: "routed-match", detail: "the in-process match for proposal-routed") {
        var builder = TrieRouteBuilder<BenchRequestContext, BenchReader, BenchResponseSender>()
        builder.register(method: .get, path: SharedRoute.path) { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            var fields = HTTPFields()
            fields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            try await responseSender.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body,
                trailer: nil
            )
        }
        return builder.finalize()
    },
    // `drain(into:)` — the same work as `+apply-direct`, without the intermediate array `drain()` returns
    // for its caller to immediately iterate and discard.
    InProcessCase(
        name: "+drain-into",
        detail: "contributions applied straight into the fields"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(staticHeaderName, SharedHeader.value))
            var fields = HTTPFields()
            try await registry.drain(into: &fields)
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // What does inserting into `HTTPFields` actually cost, and does the *first* insertion differ from the
    // rest? This is the question behind "Hummingbird's middleware is cheaper": its middleware assigns into
    // a `Response` whose headers already exist, where WireMVC may be inserting into a set built from
    // nothing. If the first insertion is dear and later ones are cheap, that is the whole difference.
    InProcessCase(name: "+fields-0", detail: "outcome with no header fields") {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            try await WireMVCOutcome(status: .ok, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    InProcessCase(name: "+fields-1", detail: "outcome with one header field") {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var fields = HTTPFields()
            fields[.contentType] = "text/plain"
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    InProcessCase(name: "+fields-2", detail: "outcome with two header fields") {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var fields = HTTPFields()
            fields[.contentType] = "text/plain"
            fields[.cacheControl] = "no-store"
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    InProcessCase(name: "+fields-3", detail: "outcome with three header fields") {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var fields = HTTPFields()
            fields[.contentType] = "text/plain"
            fields[.cacheControl] = "no-store"
            fields[staticHeaderName] = SharedHeader.value
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The registry *used*, bisected. Socketed, contributing one header measured ~3 µs above not
    // contributing — but the socketed proposal baseline carries ~2.5 µs of jitter, so that number could
    // be almost entirely measurement. These two cases sit at ~0.05 µs resolution and say which.
    InProcessCase(
        name: "+contribution",
        detail: "one header contributed, drained and resolved"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(.init(SharedHeader.name)!, SharedHeader.value))
            let fields = WireMVCResponseHeaders.resolved(middleware: try await registry.drain())
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
    // The whole mechanism as a raw route meets it: the applying sender, its deferred head, and the fused
    // send — `+contribution` minus this is the wrapper's own cost.
    InProcessCase(
        name: "+applying",
        detail: "the same, through ResponseHeaderApplyingSender"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            var registry = ResponseHeaderRegistry()
            registry.add(.set(.init(SharedHeader.name)!, SharedHeader.value))
            var body = UniqueArray<UInt8>(copying: SharedRoute.body(for: value))
            let applying = ResponseHeaderApplyingSender(wrapping: responseSender, registry: registry)
            try await applying.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    },
]
