// swift-tools-version: 6.4
import PackageDescription

/// The same concurrency rules as the app target (Xcode's "Approachable
/// Concurrency"), plus features that become the default in Swift 7, adopted
/// early. Applied to every target, so `nonisolated async` means the same thing
/// in the package as in the app: run on the caller's actor (see `@concurrent`).
let swiftSettings: [SwiftSetting] = [
    // `nonisolated async` functions run on the caller's actor; `@concurrent` opts out.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    // A main-actor type may conform to a protocol on the main actor only.
    .enableUpcomingFeature("InferIsolatedConformances"),
    // Existential types are spelled `any Decoder`, not `Decoder`.
    .enableUpcomingFeature("ExistentialAny"),
    // Members of a module are visible only in files that import it.
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "ChessCore",
    // Strings in code are English; translations live in String Catalogs.
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Rules and move generation. No dependencies, no I/O.
        .library(name: "ChessCore", targets: ["ChessCore"]),
        // WebSocket client speaking the server protocol.
        .library(name: "ChessNet", targets: ["ChessNet"]),
        // 3D piece meshes generated from profiles. Plain arrays, no RealityKit.
        .library(name: "ChessModels", targets: ["ChessModels"]),
        // The app's state and its rules, without UI or network: testable.
        .library(name: "ChessClient", targets: ["ChessClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        // gRPC: the runtime, protobuf support, and the HTTP/2 transport
        // (Network.framework on Apple platforms).
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.11.0"),
    ],
    targets: [
        .target(name: "ChessCore", swiftSettings: swiftSettings),
        // Generated from proto/ by `make proto`: messages, and gRPC clients
        // for GameInfo, AuthService and Health. Do not edit.
        .target(
            name: "ChessProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ChessNet",
            dependencies: [
                "ChessCore", "ChessProto",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "ChessModels", dependencies: ["ChessCore"], swiftSettings: swiftSettings),
        .target(
            name: "ChessClient", dependencies: ["ChessCore", "ChessNet"],
            resources: [.process("Resources")],  // Localizable.xcstrings
            swiftSettings: swiftSettings
        ),
        // Writes the pieces as .usdz files: swift run export-pieces <folder>
        .executableTarget(name: "export-pieces", dependencies: ["ChessModels"], swiftSettings: swiftSettings),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"], swiftSettings: swiftSettings),
        .testTarget(
            name: "ChessNetTests",
            dependencies: ["ChessNet", "ChessProto", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "ChessModelsTests", dependencies: ["ChessModels"], swiftSettings: swiftSettings),
        .testTarget(name: "ChessClientTests", dependencies: ["ChessClient", "ChessCore", "ChessNet"], swiftSettings: swiftSettings),
    ]
)
