// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AIChatKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AIChatCore",             targets: ["AIChatCore"]),
        .library(name: "AIChatOpenAI",           targets: ["AIChatOpenAI"]),
        .library(name: "AIChatAnthropic",        targets: ["AIChatAnthropic"]),
        .library(name: "AIChatFoundationModels", targets: ["AIChatFoundationModels"]),
        .library(name: "AIChatUI",               targets: ["AIChatUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kevinhermawan/swift-json-schema.git", .upToNextMajor(from: "2.0.1")),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git",  .upToNextMajor(from: "2.4.0")),
        .package(url: "https://github.com/JohnSundell/Splash.git",              exact: "0.16.0"),
    ],
    targets: [
        .target(
            name: "AIChatCore",
            dependencies: [.product(name: "JSONSchema", package: "swift-json-schema")],
            path: "Sources/AIChatCore"
        ),
        .testTarget(name: "AIChatCoreTests",      dependencies: ["AIChatCore"],      path: "Tests/AIChatCoreTests"),

        .target(name: "AIChatOpenAI",    dependencies: ["AIChatCore"], path: "Sources/AIChatOpenAI"),
        .testTarget(name: "AIChatOpenAITests",    dependencies: ["AIChatOpenAI"],    path: "Tests/AIChatOpenAITests"),

        .target(name: "AIChatAnthropic", dependencies: ["AIChatCore"], path: "Sources/AIChatAnthropic"),
        .testTarget(name: "AIChatAnthropicTests", dependencies: ["AIChatAnthropic"], path: "Tests/AIChatAnthropicTests"),

        .target(
            name: "AIChatFoundationModels",
            dependencies: ["AIChatCore"],
            path: "Sources/AIChatFoundationModels"
        ),
        .testTarget(name: "AIChatFoundationModelsTests", dependencies: ["AIChatFoundationModels"], path: "Tests/AIChatFoundationModelsTests"),

        .target(
            name: "AIChatUI",
            dependencies: [
                "AIChatCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash",     package: "Splash"),
            ],
            path: "Sources/AIChatUI"
        ),
        .testTarget(name: "AIChatUITests", dependencies: ["AIChatUI"], path: "Tests/AIChatUITests"),
    ]
)
