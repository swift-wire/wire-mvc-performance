// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes
public import Vapor
public import WireMVC

import NIOHTTP1

/// An `HTTPServerRouteBuilder` that registers WireMVC's collated routes on Vapor's own router.
public struct WireMVCVaporRouteBuilder: HTTPServerRouteBuilder {
    // The adapter is the top of its own stack, so it puts the courier on itself — the same thing the
    // `ServerTransport` bridge and the Hummingbird adapter do.
    public typealias RequestContext = WireMVCContext<VaporRequestContext>
    public typealias Reader = VaporReader
    public typealias ResponseSender = VaporResponseSender

    let application: Application

    public init(application: Application) {
        self.application = application
    }

    public mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming WireMVCContext<VaporRequestContext>,
                [String: Substring],
                consuming sending VaporReader,
                consuming sending VaporResponseSender
            ) async throws -> Void
    ) {
        application.on(
            HTTPMethod(rawValue: method.rawValue),
            Self.vaporPath(from: path)
        ) { request async throws -> Response in
            let collector = VaporResponseCollector()
            var pathParameters: [String: Substring] = [:]
            for (name, value) in request.parameters.allNames.map({ ($0, request.parameters.get($0)) }) {
                if let value { pathParameters[name] = Substring(value) }
            }
            try await handler(
                Self.httpRequest(from: request),
                WireMVCContext(base: VaporRequestContext(), responseHeaders: ResponseHeaderRegistry()),
                pathParameters,
                VaporReader(request.body.data),
                VaporResponseSender(collector: collector)
            )
            guard let head = collector.head else {
                throw WireMVCVaporNativeError.streamingNotSupported
            }
            var headers = HTTPHeaders()
            for field in head.headerFields {
                headers.add(name: field.name.canonicalName, value: field.value)
            }
            return Response(
                status: HTTPResponseStatus(statusCode: head.status.code),
                headers: headers,
                body: .init(buffer: collector.body)
            )
        }
    }

    /// WireMVC spells parameters `{name}` and catch-alls `{name*}`; Vapor spells them `:name` and `**`.
    static func vaporPath(from path: String) -> [PathComponent] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { segment in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else {
                return PathComponent(stringLiteral: String(segment))
            }
            let name = segment.dropFirst().dropLast()
            return name.hasSuffix("*") ? .catchall : .parameter(String(name))
        }
    }

    /// Vapor's `Request` in HTTPTypes' currency, which is what a WireMVC handler binds from.
    static func httpRequest(from request: Request) -> HTTPRequest {
        var fields = HTTPFields()
        for header in request.headers {
            if let name = HTTPField.Name(header.name) {
                fields.append(HTTPField(name: name, value: header.value))
            }
        }
        return HTTPRequest(
            method: HTTPRequest.Method(request.method.rawValue) ?? .get,
            scheme: "http",
            authority: request.headers.first(name: "host") ?? "",
            path: request.url.string,
            headerFields: fields
        )
    }
}
