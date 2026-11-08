// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipFlow", targets: ["ClipFlow"]),
        .executable(name: "ClipFlowUpdater", targets: ["ClipFlowUpdater"]),
        .executable(name: "ClipFlowSelfTest", targets: ["ClipFlowSelfTest"])
    ],
    targets: [
        .target(name: "CTerminal", path: "Sources/CTerminal", publicHeadersPath: "include"),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "ClipFlowKit",
            dependencies: ["CSQLite"],
            path: "Sources/ClipFlowKit"
        ),
        .executableTarget(
            name: "ClipFlow",
            dependencies: ["ClipFlowKit", "CTerminal"],
            path: "Sources/ClipFlow"
        ),
        .executableTarget(
            name: "ClipFlowUpdater",
            path: "Sources/ClipFlowUpdater"
        ),
        .executableTarget(
            name: "ClipFlowSelfTest",
            dependencies: ["ClipFlowKit"],
            path: "Tests/ClipFlowSelfTest"
        )
    ],
    swiftLanguageVersions: [.v5]
)
