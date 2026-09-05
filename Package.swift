// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import PackageDescription

// A benchmark harness for WireMVC's per-request cost, isolated in its own package so no shipping target
// carries a benchmark dependency, and so the servers under test can be assembled by hand rather than
// through codegen.
//
// tools-version 6.4 and macOS 26 because WireMVC is proposal-native (it dispatches over
// swift-http-api-proposal's `HTTPServer`), which is the floor its runtimes already sit on.
let package = Package(
    name: "wire-mvc-performance",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "wire-mvc-performance", targets: ["WireMVCPerformance"])
    ],
    dependencies: [
        // The `ServerTransport` trait is what the bridged scenario measures.
        .package(url: "https://github.com/swift-wire/wire-mvc.git", branch: "main", traits: ["ServerTransport"]),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-http-server.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        // Direct, for the codegen target: `@Singleton`, `@Inject` and `@Scoped(seed:)` come from Wire.
        .package(url: "https://github.com/swift-wire/swift-wire.git", branch: "main"),
        // The native-adapter prototypes, local to this repo while they are only being measured.
        // The Hummingbird adapter lives in its own repo now. A sibling path rather than a URL because it
        // is unpublished — a checkout without it beside this one will not resolve, which is the honest
        // state of a prototype that is not ready to depend on.
        .package(path: "../wire-mvc-hummingbird"),
        .package(path: "NativeAdapters/WireMVCVaporNative"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.2"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        // The one client every scenario is driven with — the point of the harness is that this is
        // identical across them, so a difference is server-side.
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            exact: "1.35.0",
            traits: ["UnstableHTTPAPIsSupport"]
        ),
    ],
    targets: [
        // Controllers built through codegen, so the scoping question can be asked of the real generated
        // shape rather than a hand-written approximation of it. Every other target here deliberately
        // avoids the plugin; this one exists because `@Scoped(seed:)` cannot be hand-written faithfully —
        // its scope-entry machinery is generated.
        .target(
            name: "PerformanceControllers",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("LifetimeDependence"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        .executableTarget(
            name: "WireMVCPerformance",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "WireMVCServerTransport", package: "wire-mvc"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "PerformanceControllers",
                .product(name: "WireMVCHummingbird", package: "wire-mvc-hummingbird"),
                .product(name: "WireMVCVaporNative", package: "WireMVCVaporNative"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("LifetimeDependence"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        )
    ]
)
