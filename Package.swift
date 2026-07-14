// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HermesMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HermesMonitorCore", targets: ["HermesMonitorCore"]),
        .executable(name: "HermesMonitorApp", targets: ["HermesMonitorApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "HermesMonitorCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "HermesMonitorApp",
            dependencies: ["HermesMonitorCore"]
        ),
        .testTarget(
            name: "HermesMonitorCoreTests",
            dependencies: ["HermesMonitorCore", "CSQLite"]
        )
    ]
)
