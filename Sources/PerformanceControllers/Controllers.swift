package import HTTPTypes
package import Wire
package import WireMVC

// The two controller shapes whose cost this target exists to compare: one constructed once for the life of
// the process, one constructed per request from a seed. Everything else about them is identical — same
// route, same parameter, same response — so a difference between them is the scoping.

/// A body binding that tolerates an empty request, declared only so the generated terminal **consumes the
/// reader**.
///
/// A typed route binding nothing from the body gets `_` for the reader in its generated closure, so the
/// request is never read. On `NIOHTTPServer` the keep-alive decision is made when the response head is
/// written and turns on whether request `.end` has arrived by then — nothing forces it to have — so the
/// connection is closed roughly one time in five, and across 20,000 pooled requests that is a certainty.
///
/// This is scaffolding for the measurement, not a recommendation: it costs both scenarios the same
/// collect, so it cancels in the app-scoped/request-scoped comparison this target exists for. The real
/// question — who should complete an empty request — is open, and neither answer is "bind a body you do
/// not want".
@RequestBinding(.body)
@propertyWrapper
package struct ConsumedBody<Value> {
    package var wrappedValue: Value
    package init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    package init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }
}

extension ConsumedBody: RequestBound where Value == Int {
    package static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Int {
        body?.count ?? 0
    }
}

package struct Echo: Codable, Sendable {
    package let value: String
    package init(value: String) { self.value = value }
}

/// **App-scoped.** One instance, built at bootstrap, shared by every request.
@Singleton
@Controller("/app")
package struct AppScopedEchoController: Sendable {
    @Get("/{value}")
    @JSONResponse
    package func echo(@Path value: String, @ConsumedBody bytes: Int) -> Echo {
        Echo(value: value)
    }
}

/// **Request-scoped.** A fresh instance per request, seeded with the request itself — the shape a
/// controller takes when it wants per-request state without threading it through every call.
@Scoped(seed: HTTPRequest.self)
@Controller("/scoped")
package struct RequestScopedEchoController: Sendable {
    @Get("/{value}")
    @JSONResponse
    package func echo(@Path value: String, @ConsumedBody bytes: Int) -> Echo {
        Echo(value: value)
    }
}
