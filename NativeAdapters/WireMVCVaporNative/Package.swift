// swift-tools-version: 6.4
import PackageDescription

// A **native** Vapor adapter for WireMVC: an `HTTPServerRouteBuilder` that registers collated routes
// straight onto Vapor's own router, with no `ServerTransport` and no OpenAPI currency types between.
//
// The Hummingbird prototype recovered 13.3 µs and 37 allocations of that bridge's 16.7 µs and 41. Vapor's
// bridge costs +40 µs and 105 allocations, so there is more to recover — and a different shape to it,
// since Vapor's own cost centre is the `async`/`EventLoopFuture` boundary rather than body conversion.
let package = Package(
    name: "wire-mvc-vapor-native",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WireMVCVaporNative", targets: ["WireMVCVaporNative"])
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            exact: "1.1.5",
            traits: ["UnstableAsyncStreaming"]
        ),
    ],
    targets: [
        .target(
            name: "WireMVCVaporNative",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "AsyncStreaming", package: "swift-async-algorithms"),
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
