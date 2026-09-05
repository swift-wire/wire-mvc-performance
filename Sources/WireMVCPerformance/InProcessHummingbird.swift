// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

// Hummingbird driven **in process** — its router and middleware exercised without a socket, so its header
// mechanism can be compared against WireMVC's on the same instrument.
//
// The socketed comparison cannot carry this question. It puts WireMVC's mechanism ~2 µs above
// Hummingbird's with a 0.85 µs run-to-run spread, while the scope-matched in-process pair puts WireMVC's
// whole mechanism at 0.59 µs, repeatable to 0.04. Two instruments disagreeing fivefold is not a result;
// putting both frameworks on the smaller one is.
//
// `Router.buildResponder()` is the seam: it returns the same responder the server would drive, so the
// router, the middleware chain and the handler all run, and only the socket is absent.

/// A context source with no channel — `RequestContextSource` only requires a logger, so a real one is not
/// needed to build a context. `ApplicationRequestContextSource` carries a `Channel` this never touches.
struct BenchHummingbirdSource: RequestContextSource {
    let logger: Logger
}

/// The minimum `RequestContext`, matching what `hummingbird-plain` uses (`BasicRequestContext`) except for
/// the source, so nothing in the measured path differs.
struct BenchHummingbirdContext: RequestContext {
    typealias Source = BenchHummingbirdSource

    var coreContext: CoreRequestContextStorage

    init(source: BenchHummingbirdSource) {
        self.coreContext = .init(source: source)
    }
}

/// The header middleware, over the bench context.
struct BenchHummingbirdHeaderMiddleware: RouterMiddleware {
    typealias Context = BenchHummingbirdContext

    @concurrent
    func handle(
        _ request: Request,
        context: BenchHummingbirdContext,
        next: @concurrent (Request, BenchHummingbirdContext) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        response.headers[staticHeaderName] = SharedHeader.value
        return response
    }
}

/// A responder for the same route the socketed scenarios serve, with or without the header middleware —
/// the pair whose difference is Hummingbird's header mechanism.
func hummingbirdResponder(contributingAHeader: Bool) -> some HTTPResponder<BenchHummingbirdContext> {
    let router = Router(context: BenchHummingbirdContext.self)
    if contributingAHeader {
        router.add(middleware: BenchHummingbirdHeaderMiddleware())
    }
    router.get("/echo/:value") { _, context in
        let value = context.parameters.get("value") ?? "<none>"
        return Response(status: .ok, body: hummingbirdBody(for: value))
    }
    return router.buildResponder()
}

/// Discards what a response body writes. Deliberately not a rendezvous, for the same reason
/// ``BenchResponseSender`` is not: suspending until a consumer takes each chunk would put a scheduler hop
/// inside the thing being measured.
struct DiscardingBodyWriter: ResponseBodyWriter {
    mutating func write(_ buffer: ByteBuffer) async throws {}
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

/// Drive a Hummingbird responder, returning each request's latency in microseconds.
///
/// The response body is consumed, because the socketed path writes it and a comparison that skipped it
/// would price a different amount of work on each side.
/// > Important: `@concurrent`, and it is worth 15 µs of the 16 this used to report.
/// > `HTTPResponder.respond` is `@Sendable`, and this package enables `NonisolatedNonsendingByDefault`
/// > while Hummingbird does not. Driven from a `nonisolated(nonsending)` caller, every request hopped to
/// > the global executor and back — twice, counting the body write — and the hops, not Hummingbird, were
/// > what the clock saw: `hb-plain` read **15.9 µs** that way and reads **1.04** on the executor the call
/// > actually wants. A real server already drives the responder from there, which is why the socketed
/// > rows never showed it. The WireMVC cases were checked for the same fault and do not have it —
/// > `HTTPServerRequestHandler.handle` is `nonisolated(nonsending)`, so it runs inline on whichever
/// > executor the caller is on: `routed-match` measures 0.88 either way.
@concurrent
func driveHummingbird(
    _ responder: some HTTPResponder<BenchHummingbirdContext>,
    warmup: Int,
    iterations: Int
) async throws -> [Double] {
    let source = BenchHummingbirdSource(logger: Logger(label: "perf"))
    let head = HTTPRequest(method: .get, scheme: "http", authority: "bench", path: "/echo/benchmark")

    // Built once. A server builds one per request, but `RequestBody` wraps an async sequence and its
    // construction dominated everything else — 16 µs of a 17 µs measurement — which would make the header
    // delta a small difference between two large numbers. The handler never reads the body.
    let request = Request(head: head, body: .init(buffer: ByteBuffer()))

    func once() async throws {
        let response = try await responder.respond(
            to: request,
            context: BenchHummingbirdContext(source: source)
        )
        try await response.body.write(DiscardingBodyWriter())
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
