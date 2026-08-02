// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SearchMyMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SearchMyMacCore", targets: ["SearchMyMacCore"]),
        .executable(name: "SearchMyMac", targets: ["SearchMyMacApp"]),
        .executable(name: "SearchMyMacEngineService", targets: ["SearchMyMacEngineService"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "SearchMyMacCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "SearchMyMacApp",
            dependencies: ["SearchMyMacCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "SearchMyMacEngineService",
            dependencies: ["SearchMyMacCore"]
        ),
        .testTarget(
            name: "SearchMyMacCoreTests",
            dependencies: ["SearchMyMacCore"]
        )
    ]
)
