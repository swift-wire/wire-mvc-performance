import BasicContainers
import HTTPAPIs
import HTTPTypes
import Hummingbird
import Logging
import NIOHTTPServer
// Conformance-only: `extension Router: ServerTransport`, which the bridged scenario needs and no symbol
// here names.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import WireMVC
import WireMVCRouter
import WireMVCServerTransport

/// One server under test. Each starts on an ephemeral port, serves ``SharedRoute``, and is driven by the
/// same client — so what differs between scenarios is the stack a request traverses.
protocol Scenario: Sendable {
    var name: String { get }
    var detail: String { get }
    /// The path to drive. Defaulted, because every scenario but the codegen'd pair serves the same route —
    /// and those two differ only in which of one graph's two routes is hit.
    var path: String { get }
    /// Run until cancelled, calling `ready` with the bound port once serving.
    func run(ready: @Sendable @escaping (Int) -> Void) async throws
}

extension Scenario {
    var path: String { "/echo/benchmark" }
}

/// **The floor.** A plain Hummingbird route touching no WireMVC machinery.
///
/// Not a fair comparison to a framework — it has no middleware chain, no response-header registry, no
/// error tiers — and that is the point. It bounds what any amount of WireMVC optimisation could approach.
struct HummingbirdPlain: Scenario {
    let name = "hummingbird-plain"
    let detail = "plain Hummingbird route, no WireMVC"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let router = Router()
        router.get("/echo/:value") { _, context in
            let value = context.parameters.get("value") ?? "<none>"
            return Response(status: .ok, body: hummingbirdBody(for: value))
        }
        try await serveHummingbird(router: router, ready: ready)
    }
}

/// **Hummingbird with no router at all** — a bare `HTTPResponder` on its server.
///
/// The counterpart to `proposal-plain`, which is also routerless. Without this, "plain Hummingbird"
/// silently includes Hummingbird's router while the proposal baseline includes none, so the two floors
/// are not the same floor and only *within*-framework deltas mean anything.
struct HummingbirdRaw: Scenario {
    let name = "hummingbird-raw"
    let detail = "Hummingbird server, no router"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let app = Application(
            responder: EchoResponder(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in ready(channel.localAddress?.port ?? 0) }
        )
        try await app.runService()
    }
}

/// Matches `/echo/<value>` by hand, so the comparison is against the *server* rather than a router.
struct EchoResponder: HTTPResponder {
    func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
        let value = request.uri.path.split(separator: "/").dropFirst().first.map(String.init) ?? "<none>"
        return Response(status: .ok, body: hummingbirdBody(for: value))
    }
}

/// The header every "+ one response header" scenario contributes, so the three frameworks are adding the
/// same thing by the same amount and only the mechanism differs.
enum SharedHeader {
    static let name = "x-wire"
    static let value = "1"
}

/// Hummingbird's mechanism: a router middleware that sets a field on the way out.
struct HummingbirdHeaderMiddleware<Context: RequestContext>: RouterMiddleware {
    // `@concurrent` on both the method and `next`: this package enables
    // `NonisolatedNonsendingByDefault` and Hummingbird does not, so without saying so the conformance is
    // inferred with the new default and does not match the requirement's isolation.
    @concurrent
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.init(SharedHeader.name)!] = SharedHeader.value
        return response
    }
}

/// The payload the typed scenarios answer with — the same shape `PerformanceControllers.Echo` uses, so
/// the three frameworks encode the same object.
struct EchoPayload: ResponseCodable {
    let value: String
}

/// **A Hummingbird typed route**: binds a path parameter, reads the body, returns a `Codable`.
///
/// The counterpart to `codegen-app-scoped`. `hummingbird-plain` writes raw bytes and reads nothing, so it
/// cannot be compared against a WireMVC controller that encodes JSON and collects the request — this can.
/// The body read is deliberate: WireMVC's generated terminal collects it, so leaving it out here would
/// price a different amount of work on each side.
struct HummingbirdTyped: Scenario {
    let name = "hummingbird-typed"
    let detail = "Hummingbird route returning Codable, body collected"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let router = Router()
        router.get("/echo/:value") { request, context in
            _ = try await request.body.collect(upTo: 1024)
            let value = context.parameters.get("value") ?? "<none>"
            return EchoPayload(value: value)
        }
        try await serveHummingbird(router: router, ready: ready)
    }
}

/// **Hummingbird's router plus one response-header middleware.**
///
/// The counterpart to WireMVC's courier and registry: same capability — something upstream of the handler
/// contributing a field to whatever head the handler writes — priced against the same framework's plain
/// routed scenario, so what is left is the mechanism.
struct HummingbirdHeaders: Scenario {
    let name = "hummingbird-headers"
    let detail = "Hummingbird route + a response-header middleware"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let router = Router()
        router.add(middleware: HummingbirdHeaderMiddleware())
        router.get("/echo/:value") { _, context in
            let value = context.parameters.get("value") ?? "<none>"
            return Response(status: .ok, body: hummingbirdBody(for: value))
        }
        try await serveHummingbird(router: router, ready: ready)
    }
}

/// **WireMVC through the `ServerTransport` bridge** — what Hummingbird and Vapor runtimes actually do.
///
/// The request crosses into OpenAPI's currency types, then into WireMVC's, and the handler runs in an
/// unstructured `Task` whose response is collected through a `ResponseChannel`.
struct HummingbirdBridged: Scenario {
    let name = "hummingbird-bridged"
    let detail = "WireMVC via WireMVCServerTransport"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let router = Router()
        _ = try WireMVCServerTransport.apply(EchoGraph(), to: router)
        try await serveHummingbird(router: router, ready: ready)
    }
}

/// **The proposal server's own floor** — a bare `NIOHTTPServer` with a hand-written request handler and
/// no WireMVC at all.
///
/// The counterpart to ``HummingbirdPlain``, and the reason both exist: comparing each framework's bare
/// server to itself-plus-WireMVC isolates WireMVC's cost from the HTTP server's, which comparing across
/// frameworks cannot do.
struct ProposalPlain: Scenario {
    let name = "proposal-plain"
    let detail = "bare NIOHTTPServer, no WireMVC"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        // The server's *own* `serve`, not `WireMVC.serve`: this scenario is the bare floor, and routing a
        // baseline through WireMVC's service running would put part of what is being measured into the
        // thing it is measured against.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: server, to: ready) }
            try await server.serve(handler: EchoHandler())
        }
    }
}

/// The bare handler: matches `/echo/<value>` by hand, so the comparison is against the *server*, not
/// against a router someone else wrote.
struct EchoHandler: HTTPServerRequestHandler {
    func handle(
        request: HTTPRequest,
        requestContext: consuming NIOHTTPServer.RequestContext,
        reader: consuming sending NIOHTTPServer.Reader,
        responseSender: consuming sending NIOHTTPServer.ResponseSender
    ) async throws {
        // Drained for the same reason the WireMVC route drains it — see `EchoController`.
        var reader = reader
        var drained = UniqueArray<UInt8>()
        _ = try await reader.collect(into: &drained, maximumSize: 0)
        let path = request.path ?? "/"
        let value = path.split(separator: "/").dropFirst().first.map(String.init) ?? "<none>"
        let bytes = SharedRoute.body(for: value)
        // `Content-Length` explicitly, under the same knob the WireMVC route uses. This scenario has no
        // WireMVC in it at all, so `FRAMING=chunked` here prices *chunking itself* on the bare server —
        // which is what separates "chunked framing costs this much" from "WireMVC costs this much".
        var fields = HTTPFields()
        if statesContentLength { fields[.contentLength] = String(bytes.count) }
        var body = UniqueArray<UInt8>(copying: bytes)
        try await responseSender.sendAndFinish(
            HTTPResponse(status: .ok, headerFields: fields),
            buffer: &body
        )
    }
}

/// **The bare handler, served through `WireMVC.serve`.**
///
/// The control for the one difference `proposal-plain` and `proposal-native` still had besides the
/// handler: the former runs `NIOHTTPServer.serve(handler:)` directly, the latter `WireMVC.serve`, which
/// runs the server under ServiceLifecycle. Same handler as `proposal-plain`, same serving path as
/// `proposal-native`, so the two subtractions separate the serving path from the request handling.
struct ProposalPlainServed: Scenario {
    let name = "proposal-plain-served"
    let detail = "bare handler, via WireMVC.serve"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: server, to: ready) }
            try await WireMVC.serve(on: server, handler: EchoHandler(), services: [])
        }
    }
}

/// **WireMVC on the proposal-native path** — its own router over `NIOHTTPServer`, no bridge.
///
/// The comparison that matters: whatever separates this from the bridged scenario is what the bridge
/// costs, and whatever separates it from the plain scenario is what WireMVC's own tiers cost. Only the
/// former is what a per-framework adapter could recover.
struct ProposalNative: Scenario {
    let name = "proposal-native"
    let detail = "WireMVC's own router on NIOHTTPServer"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let base = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        let server = WireMVCContextServer(base)
        var builder = TrieRouteBuilder(for: server)
        let services = try WireMVC.apply(EchoGraph(), to: &builder)
        let handler = builder.finalize()
        // The bound port is only known once the server is listening, so it is read from the server's own
        // `listeningAddresses`, which resolves at that moment.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: base, to: ready) }
            try await WireMVC.serve(on: server, handler: handler, services: services)
        }
    }
}

/// **WireMVC's router, and nothing else** — the trie served directly on the bare server, with no courier
/// and no response-header registry.
///
/// This exists to make one comparison honest. `proposal-native` goes through `WireMVCContextServer`, which
/// builds a `WireMVCContext` and a `ResponseHeaderRegistry` per request before the router is reached — so
/// its delta prices routing *plus* a capability that `hummingbird-plain` and `vapor-plain` have no
/// equivalent of. Comparing that against "Hummingbird's own router" charged WireMVC for something the
/// other side was not carrying.
///
/// Here the scope matches: a server, a router that matches a path and binds a parameter, and a handler.
/// Whatever separates this from `proposal-plain` is WireMVC's routing, on the same terms the other two
/// frameworks' routers are priced on. The courier and registry are then `proposal-native` minus this.
struct ProposalRouted: Scenario {
    let name = "proposal-routed"
    let detail = "WireMVC's router alone, no courier"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        var builder = TrieRouteBuilder(for: server)
        builder.register(method: .get, path: SharedRoute.path) { _, _, parameters, reader, responseSender in
            // Same body as `EchoController`, for the same reasons — drained reader, stated length.
            var reader = reader
            var drained = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &drained, maximumSize: 0)
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            var fields = HTTPFields()
            if statesContentLength { fields[.contentLength] = String(bytes.count) }
            var body = UniqueArray<UInt8>(copying: bytes)
            try await responseSender.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body
            )
        }
        let handler = builder.finalize()
        // The server's own `serve`, not `WireMVC.serve`: this scenario is the router by itself.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: server, to: ready) }
            try await server.serve(handler: handler)
        }
    }
}

/// **No wrapper, but the base sender's three-argument `sendAndFinish`.**
///
/// The wrapper changes which path the *base* takes. A bare `sendAndFinish(response, buffer:)` is the
/// two-argument spelling, which binds to the proposal's extension and expands to `send` + `finish`. Through
/// the wrapper the base is instead handed the three-argument witness, fused. If those two paths differ in
/// the server, the difference is the server's and not the wrapper's — this says which.
struct ProposalFused: Scenario {
    let name = "proposal-fused"
    let detail = "no wrapper, explicit three-argument sendAndFinish"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        var builder = TrieRouteBuilder(for: server)
        builder.register(method: .get, path: SharedRoute.path) { _, _, parameters, reader, responseSender in
            var reader = reader
            var drained = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &drained, maximumSize: 0)
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            var fields = HTTPFields()
            fields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            // The three-argument spelling, explicitly — this reaches the conformer's witness where the
            // two-argument one cannot.
            try await responseSender.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body,
                trailer: nil
            )
        }
        let handler = builder.finalize()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: server, to: ready) }
            try await server.serve(handler: handler)
        }
    }
}

/// **The applying sender, wrapping, with nothing contributed.**
///
/// Sits between `proposal-native` (courier and registry, no wrapper) and `proposal-headers` (wrapper and a
/// contribution), so the two gaps separate what the wrapper and its deferred head cost from what
/// registering, draining and applying a contribution costs. Without it the whole mechanism is one number.
struct ProposalWrapped: Scenario {
    let name = "proposal-wrapped"
    let detail = "WireMVC's router + the applying sender, nothing contributed"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let base = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        let server = WireMVCContextServer(base)
        var builder = TrieRouteBuilder(for: server)
        builder.register(method: .get, path: SharedRoute.path) { _, context, parameters, reader, sender in
            var reader = reader
            var drained = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &drained, maximumSize: 0)
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            // The handler states its own length, so the wrapper's `stateLengthIfAbsent` is a no-op and
            // this scenario isolates the wrapper's *machinery* from the header insertion it would
            // otherwise perform — an insertion the unwrapped scenarios do in their handler instead.
            var fields = HTTPFields()
            fields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            let applying = ResponseHeaderApplyingSender(wrapping: sender, registry: context.responseHeaders)
            try await applying.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body
            )
        }
        let handler = builder.finalize()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: base, to: ready) }
            try await base.serve(handler: WireMVCContextHandler(inner: handler))
        }
    }
}

/// **WireMVC's router plus one contributed response header** — the courier's registry actually used.
///
/// `proposal-routed` prices the router alone and `proposal-native` adds the courier and registry unused.
/// This is the third point: something contributes a field, and it reaches the head. That is the
/// like-for-like against ``HummingbirdHeaders`` and ``VaporHeaders``, which do the same thing through
/// their frameworks' middleware.
///
/// The sender is wrapped in `ResponseHeaderApplyingSender` by hand because this contributor registers
/// straight onto the builder; a real `@RawRoute` gets that wrapping from codegen. Without it the
/// contribution would be collected and never applied, which would measure half the mechanism.
///
/// Always length-framed, whatever `FRAMING` says: the wrapper states the length itself now, so this one
/// scenario cannot be made chunked and should only be compared under the default.
struct ProposalHeaders: Scenario {
    let name = "proposal-headers"
    let detail = "WireMVC's router + a contributed response header"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let base = NIOHTTPServer(
            logger: Logger(label: "perf"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        let server = WireMVCContextServer(base)
        var builder = TrieRouteBuilder(for: server)
        builder.register(method: .get, path: SharedRoute.path) { _, context, parameters, reader, sender in
            var reader = reader
            var drained = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &drained, maximumSize: 0)
            let registry = context.responseHeaders
            registry.add(.set(.init(SharedHeader.name)!, SharedHeader.value))
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            // States its own length, exactly as `proposal-wrapped` does, so the two differ **only** by the
            // contribution. Leaving it to the wrapper would put a `Content-Length` insertion in this
            // scenario's column and none in the other's, and the marginal would price both at once.
            var fields = HTTPFields()
            fields[.contentLength] = String(bytes.count)
            var body = UniqueArray<UInt8>(copying: bytes)
            let applying = ResponseHeaderApplyingSender(wrapping: sender, registry: registry)
            try await applying.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body
            )
        }
        let handler = builder.finalize()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: base, to: ready) }
            try await base.serve(handler: WireMVCContextHandler(inner: handler))
        }
    }
}

/// Await the proposal server's bound address and report its port.
func reportPort(
    of server: NIOHTTPServer,
    to ready: @Sendable @escaping (Int) -> Void
) async throws {
    guard let port = try await server.listeningAddresses.first?.port else { return }
    ready(port)
}

/// Serve a Hummingbird router on an ephemeral port, reporting it once bound.
func serveHummingbird(
    router: Router<BasicRequestContext>,
    ready: @Sendable @escaping (Int) -> Void
) async throws {
    let app = Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { channel in
            ready(channel.localAddress?.port ?? 0)
        }
    )
    try await app.runService()
}

/// The response body every Hummingbird scenario returns.
///
/// `FRAMING=chunked` switches to a *streamed* body — how a Hummingbird response ends up chunked, since
/// Hummingbird derives `Content-Length` from a `ByteBuffer` body and there is no header to simply omit.
/// See ``vaporBody(for:)`` for why that makes these rows a different code path rather than the same one
/// framed differently.
func hummingbirdBody(for value: String) -> ResponseBody {
    let buffer = ByteBuffer(bytes: SharedRoute.body(for: value))
    guard statesContentLength else {
        return .init(asyncSequence: AsyncStream<ByteBuffer> { continuation in
            continuation.yield(buffer)
            continuation.finish()
        })
    }
    return .init(byteBuffer: buffer)
}
