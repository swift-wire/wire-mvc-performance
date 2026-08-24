package import WireMVC

// The generated graph is `internal` to this module and its bootstrap is file-private, so nothing outside
// can reach either. That is the right default — an app's wiring is not API — but this target exists to be
// measured from the harness, so it needs one seam.
//
// `Wire.bootstrap()` and `_WireGraph` are internal rather than private, so a second file in the same
// target can call one and return the other. Nothing about the graph is exposed beyond the protocol the
// harness already builds routers from.

/// The composed graph, as `WireMVCComposable` — the same thing `@WireMVCBootstrap` would hand a server.
package func composedGraph() async throws -> some WireMVCComposable {
    try await Wire.bootstrap()
}
