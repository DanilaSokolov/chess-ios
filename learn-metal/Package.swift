// swift-tools-version: 6.4
// Учебные уроки по Metal. Каждый урок — отдельная программа:
//
//   swift run Lesson1Triangle
//
// Можно открыть Package.swift в Xcode и запускать уроки там: так доступен
// отладчик GPU (Debug → Capture GPU Workload).
import PackageDescription

/// Те же правила, что у игры (apple/ChessCore/Package.swift): поведение
/// конкурентности как в Xcode-таргете с Approachable Concurrency, плюс
/// фичи, которые станут обязательными в Swift 7.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "LearnMetal",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LessonKit", swiftSettings: swiftSettings),
        .executableTarget(name: "Lesson1Triangle", dependencies: ["LessonKit"], swiftSettings: swiftSettings),
        .executableTarget(name: "Lesson2Board", dependencies: ["LessonKit"], swiftSettings: swiftSettings),
        .executableTarget(name: "Lesson3Pawn", dependencies: ["LessonKit"], swiftSettings: swiftSettings),
        .executableTarget(name: "Lesson4Compute", swiftSettings: swiftSettings),
        // Модули игры, подключённые символическими ссылками на apple/ChessCore/Sources:
        // урок 5 рисует те же фигуры, что 3D-доска, только без RealityKit.
        .target(name: "ChessCore", swiftSettings: swiftSettings),
        .target(name: "ChessModels", dependencies: ["ChessCore"], swiftSettings: swiftSettings),
        .executableTarget(name: "Lesson5Pieces", dependencies: ["LessonKit", "ChessModels"], swiftSettings: swiftSettings),
    ]
)
