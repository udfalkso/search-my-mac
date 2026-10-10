// swift-tools-version: 6.0
import PackageDescription
import Foundation

let isAppStore = ProcessInfo.processInfo.environment["SMM_APP_STORE"] == "1"

let package = Package(
    name: "SearchMyMac",
    platforms: [.macOS("13.3")],
    products: [
        .library(name: "SearchMyMacCore", targets: ["SearchMyMacCore"]),
        .executable(name: "SearchMyMac", targets: ["SearchMyMacApp"]),
        .executable(name: "smm", targets: ["SearchMyMacCLI"]),
        .executable(name: "semantic-benchmark", targets: ["SemanticBenchmark"]),
        .executable(name: "SearchMyMacEngineService", targets: ["SearchMyMacEngineService"])
    ],
    dependencies: [
        .package(url: "https://github.com/unum-cloud/USearch.git", exact: "2.26.0")
    ] + (isAppStore ? [] : [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")]),
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "SearchMyMacCore",
            dependencies: [
                "CSQLite",
                "LlamaFramework",
                .product(name: "USearch", package: "USearch")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "SearchMyMacApp",
            dependencies: [
                "SearchMyMacCore"
            ] + (isAppStore ? [] : [.product(name: "Sparkle", package: "Sparkle")]),
            swiftSettings: isAppStore ? [.define("SMM_APP_STORE")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "SearchMyMacCLI",
            dependencies: ["SearchMyMacCore"]
        ),
        .executableTarget(
            name: "SemanticBenchmark",
            dependencies: ["SearchMyMacCore"]
        ),
        .executableTarget(
            name: "SearchMyMacEngineService",
            dependencies: ["SearchMyMacCore"]
        ),
        .testTarget(
            name: "SearchMyMacAppTests",
            dependencies: ["SearchMyMacApp"]
        ),
        .testTarget(
            name: "SearchMyMacCoreTests",
            dependencies: ["SearchMyMacCore"]
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9632/llama-b9632-xcframework.zip",
            checksum: "a5f03d5dc7dcf30aa22b4def2540b7b59ed1f65fcd9beb1c37bc7875ddae17e8"
        )
    ]
)
