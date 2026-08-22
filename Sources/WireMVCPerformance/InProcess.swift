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

/// Drive the courier-wrapped router, returning each request's latency in microseconds.
func driveCourier(warmup: Int, iterations: Int) async throws -> [Double] {
    let handler = courierRouter()
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
    InProcessCase(
        name: "+registry",
        detail: "outcome, with a response-header registry drained into it"
    ) {
        router { _, _, parameters, _, responseSender in
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let registry = ResponseHeaderRegistry()
            let fields = WireMVCResponseHeaders.resolved(middleware: try await registry.drain())
            try await WireMVCOutcome(status: .ok, headerFields: fields, body: SharedRoute.body(for: value))
                .send(on: responseSender)
        }
    },
]
