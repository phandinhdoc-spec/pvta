// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PVTA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pvta", targets: ["PVTACLI"]),
        .executable(name: "PVTADesktop", targets: ["PVTADesktop"]),
    ],
    targets: [
        .target(name: "PVTACore"),
        .executableTarget(name: "PVTACLI", dependencies: ["PVTACore"]),
        .executableTarget(name: "PVTADesktop", dependencies: ["PVTACore"]),
        .testTarget(name: "PVTACoreTests", dependencies: ["PVTACore", "PVTADesktop"]),
        .testTarget(
            name: "NhapDuLieuTests",
            dependencies: ["PVTACore"],
            path: "Tests/NhapDuLieuTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["PVTACore"],
            path: "Tests/CLITests"
        ),
    ]
)
