// swift-tools-version: 5.9
import PackageDescription

var packageTargets: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        pkgConfig: "sqlite3",
        providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "HermesMonitorCore",
        dependencies: ["CSQLite"],
        resources: [
            .copy("Resources/RemoteSQLiteSnapshot.py"),
            .copy("Resources/TaskInstructionHelper.py"),
            .copy("Resources/TaskFamilyArchiveHelper.py")
        ],
        linkerSettings: [
            .linkedFramework("Security", .when(platforms: [.macOS]))
        ]
    ),
    .executableTarget(
        name: "HermesMonitorApp",
        dependencies: ["HermesMonitorCore"],
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
            .linkedFramework("Carbon", .when(platforms: [.macOS])),
            .linkedFramework("UserNotifications", .when(platforms: [.macOS]))
        ]
    ),
    .testTarget(
        name: "HermesMonitorCoreTests",
        dependencies: ["HermesMonitorCore", "CSQLite"]
    )
]

#if os(macOS)
packageTargets.append(
    .testTarget(
        name: "HermesMonitorAppTests",
        dependencies: ["HermesMonitorApp", "HermesMonitorCore"]
    )
)
#endif

let package = Package(
    name: "HermesMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HermesMonitorCore", targets: ["HermesMonitorCore"]),
        .executable(name: "HermesMonitorApp", targets: ["HermesMonitorApp"])
    ],
    targets: packageTargets
)
