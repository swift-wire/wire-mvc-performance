// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPAPIs
import Logging
import NIOHTTPServer
import PerformanceControllers
import WireMVC
import WireMVCRouter

// Codegen'd controllers, so the scoping question is asked of the shape the plugin actually emits.
//
// Everything else in this harness is hand-written on purpose — no macro chooses anything in the measured
// path. That is not possible here: an app-scoped controller's route closure calls a stored instance, while
// a request-scoped one does
//
//     let (controller, teardown) = try await self._wireEnterScope(request)
//     defer { _ = await teardown() }
//
// per request — scope entry and teardown, both `async`, around every call. Hand-writing that would be
// guessing at generated code, which is the thing this file avoids.
//
// Both controllers are in one graph and differ only in the `@Scoped(seed:)` attribute, so the difference
// between the two routes is the scoping and nothing else.

/// Serve the codegen'd graph, whose two routes differ only in scope.
struct ScopedControllerScenario: Scenario {
    let name: String
    let detail: String
    /// `/app/benchmark` or `/scoped/benchmark` — the same graph either way, so the servers are identical
    /// and only the path differs.
    let path: String

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
        let services = try await WireMVC.apply(composedGraph(), to: &builder)
        let handler = builder.finalize()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reportPort(of: base, to: ready) }
            try await WireMVC.serve(on: server, handler: handler, services: services)
        }
    }
}
