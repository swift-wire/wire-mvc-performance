// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-performance project authors

import BasicContainers
import Foundation
import HTTPTypes
import ServiceLifecycle
import WireMVC

/// Whether the WireMVC route states a `Content-Length`. `FRAMING=chunked` makes it not, reproducing the
/// behaviour WireMVC shipped before `WireMVCOutcome.send` stated the length it already held.
///
/// A knob rather than a fixed choice because the difference turned out to be worth several microseconds
/// and a whole p99 tail — and because that was invisible for as long as framing was something the harness
/// set once and never varied. Every non-WireMVC scenario states a length unconditionally, so with
/// `FRAMING=chunked` the WireMVC scenarios are the only ones that differ, which is what made the
/// comparison misleading.
let statesContentLength = ProcessInfo.processInfo.environment["FRAMING"] != "chunked"

/// The one route every scenario serves, so a difference between scenarios is the *path a request takes*
/// and not the work it does at the end of it.
///
/// Deliberately trivial — echo a path parameter into a small body. A benchmark whose handler does real
/// work measures the work; this one is trying to measure the framework around it, so the handler is as
/// close to nothing as a route can be while still binding a parameter and writing a body.
///
/// The consequence is worth stating where it will be read: fixed overhead is the *whole* of these numbers,
/// so a ratio between scenarios is the most flattering possible presentation of a difference. An
/// application handler that touches a database moves every scenario by the same absolute amount and makes
/// the ratio approach 1. Compare the microseconds, not the multiples.
enum SharedRoute {
    static let path = "/echo/{value}"
    static let template = "value"

    /// The bytes every scenario answers with, for a given bound parameter.
    static func body(for value: String) -> [UInt8] {
        Array("echo:\(value)".utf8)
    }
}

/// A hand-written `RouteContributor` — what `@Controller` would generate, written out so the harness needs
/// no codegen and so the measured path contains nothing a macro chose.
struct EchoController: RouteContributor {
    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: SharedRoute.path) { _, _, parameters, reader, responseSender in
            // The reader is drained even though this route has no body to read. A handler that never
            // consumes the request leaves it unfinished, and `HTTPKeepAliveHandler` closes the connection
            // once the response ends — which makes every second request on a pooled connection fail. The
            // typed tiers collect the body in their terminal, so a real route does this without saying so;
            // a hand-written one has to.
            var reader = reader
            var drained = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &drained, maximumSize: 0)
            let value = parameters[SharedRoute.template].map(String.init) ?? "<none>"
            let bytes = SharedRoute.body(for: value)
            // `Content-Length`, stated by hand because this contributor registers straight onto the route
            // builder and so bypasses codegen — which is what wraps a real `@RawRoute`'s sender in
            // `ResponseHeaderApplyingSender`, the thing that states the length for raw routes now. Setting
            // it here models the typed tier, where `WireMVCOutcome.send` states it.
            var fields = HTTPFields()
            if statesContentLength { fields[.contentLength] = String(bytes.count) }
            var body = UniqueArray<UInt8>(copying: bytes)
            // The **three-argument** spelling, deliberately: the two-argument one binds to the proposal's
            // extension and expands to `send` + `finish`, so a conformer's fused `sendAndFinish` witness is
            // never reached. On the bridge that is the difference between the one-shot known-length path
            // and the streaming rendezvous.
            try await responseSender.sendAndFinish(
                HTTPResponse(status: .ok, headerFields: fields),
                buffer: &body,
                trailer: nil
            )
        }
    }
}

/// Stands in for `Wire.bootstrap()`'s collated graph.
struct EchoGraph: WireMVCComposable {
    var routeContributors: [any RouteContributor] { [EchoController()] }
    var services: [any Service] { [] }
}
