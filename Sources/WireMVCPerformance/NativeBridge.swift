import Hummingbird
import HTTPTypes
import WireMVC
import WireMVCHummingbird

// **The native Hummingbird adapter**, against the `ServerTransport` bridge that serves the same graph.
//
// `hummingbird-bridged` costs +16 µs and 41 allocations per request over `hummingbird-plain`. Two things
// are bundled in that: the crossing into OpenAPI's currency types, and the unstructured `Task` plus
// rendezvous channel that `ServerTransport.register`'s return-based shape forces. This scenario removes
// both for a one-shot response — the handler completes inside the route closure — so the difference
// between the two is what the bridge's *shape* costs, as opposed to what mounting on Hummingbird costs.

struct HummingbirdNative: Scenario {
    let name = "hummingbird-native"
    let detail = "WireMVC mounted directly on Hummingbird's router"

    func run(ready: @Sendable @escaping (Int) -> Void) async throws {
        let router = Router()
        var builder = WireMVCHummingbirdRouteBuilder(router: router)
        _ = try WireMVC.apply(EchoGraph(), to: &builder)
        try await serveHummingbird(router: router, ready: ready)
    }
}
