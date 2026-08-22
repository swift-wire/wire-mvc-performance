import HTTPTypes
import NIOCore
import OpenAPIVapor
import ServiceLifecycle
import Vapor
import WireMVCServerTransport

// Vapor's scenarios live in their own file: Hummingbird and Vapor both define `Application`, `Request`
// and `Response`, so sharing one file would mean qualifying every use of all three.

/// **Vapor's floor.** A plain Vapor route touching no WireMVC machinery — the counterpart to
/// ``HummingbirdPlain``, so WireMVC's cost on Vapor is measured against Vapor rather than against
/// something else.
struct VaporPlain: Scenario {
    let name = "vapor-plain"
    let detail = "plain Vapor route, no WireMVC"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        try await serveVapor(ready: ready) { app in
            app.get("echo", ":value") { request in
                let value = request.parameters.get("value") ?? "<none>"
                return Response(status: .ok, body: vaporBody(for: value))
            }
        }
    }
}

/// **Vapor with no router at all** — a responder installed directly, bypassing routing.
///
/// The counterpart to `hummingbird-raw` and `proposal-plain`.
struct VaporRaw: Scenario {
    let name = "vapor-raw"
    let detail = "Vapor server, no router"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        try await serveVapor(ready: ready) { app in
            app.responder.use { _ in EchoVaporResponder() }
        }
    }
}

/// Matches `/echo/<value>` by hand, for the same reason ``EchoResponder`` does on Hummingbird.
///
/// `Vapor.Responder` is future-based rather than `async`, and the response is built synchronously here, so
/// this floor is if anything *generous* to Vapor — it skips the async hop the routed scenarios pay. That
/// makes the router delta below an upper bound rather than an exact figure.
struct EchoVaporResponder: Vapor.Responder {
    func respond(to request: Request) -> EventLoopFuture<Response> {
        let value = request.url.path.split(separator: "/").dropFirst().first.map(String.init) ?? "<none>"
        return request.eventLoop.makeSucceededFuture(Response(status: .ok, body: vaporBody(for: value)))
    }
}

/// **WireMVC through the bridge, on Vapor.** The same measurement as ``HummingbirdBridged``, on the other
/// host — the bridge does the same two conversions either way, and this is what says so rather than
/// assuming it.
struct VaporBridged: Scenario {
    let name = "vapor-bridged"
    let detail = "WireMVC via WireMVCServerTransport"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        try await serveVapor(ready: ready) { app in
            _ = try WireMVCServerTransport.apply(EchoGraph(), to: VaporTransport(routesBuilder: app))
        }
    }
}

/// Build, start and serve a Vapor app on an ephemeral port, reporting it once bound.
private func serveVapor(
    ready: @Sendable @escaping (Int) -> Void,
    configure: (Application) throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 0
    // Vapor logs a line per request at `info`, which at benchmark rates is a measurement of logging.
    app.logger.logLevel = .critical
    do {
        try configure(app)
        try await app.startup()
        if let port = app.http.server.shared.localAddress?.port { ready(port) }
        try await gracefulShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// The response body every Vapor scenario returns.
///
/// `FRAMING=chunked` switches to a *streamed* body, which is how a Vapor response ends up chunked — Vapor
/// derives `Content-Length` from a buffered body, so there is no header to simply omit. That makes the
/// chunked rows a different code path rather than the same one framed differently, and their p50 carries
/// the streaming machinery as well as the framing. The p99 is the reason they exist: the question was
/// whether chunking's tail appears on every server or only the proposal one.
func vaporBody(for value: String) -> Response.Body {
    let buffer = ByteBuffer(bytes: SharedRoute.body(for: value))
    guard statesContentLength else {
        return .init(stream: { writer in
            _ = writer.write(.buffer(buffer))
            _ = writer.write(.end)
        })
    }
    return .init(buffer: buffer)
}
