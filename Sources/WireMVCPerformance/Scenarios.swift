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
    /// Run until cancelled, calling `ready` with the bound port once serving.
    func run(ready: @Sendable @escaping (Int) -> Void) async throws
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

/// Await the proposal server's bound address and report its port.
private func reportPort(
    of server: NIOHTTPServer,
    to ready: @Sendable @escaping (Int) -> Void
) async throws {
    guard let port = try await server.listeningAddresses.first?.port else { return }
    ready(port)
}

/// Serve a Hummingbird router on an ephemeral port, reporting it once bound.
private func serveHummingbird(
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
