// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slant",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TestKit"),
        .target(name: "LidSensor"),
        .target(name: "LidMotion"),
        .target(name: "DesktopCapture", dependencies: ["FoldRenderer"]),
        .target(name: "FoldOverlay"),
        .target(name: "FoldRenderer", dependencies: ["LidMotion"], resources: [.copy("Fold.metal")]),
        .target(name: "MenuBar"),
        .target(name: "Lifecycle"),
        .executableTarget(
            name: "SlantApp",
            dependencies: ["LidSensor", "LidMotion", "DesktopCapture",
                           "FoldOverlay", "FoldRenderer", "MenuBar", "Lifecycle"]
        ),
        .executableTarget(
            name: "SlantTests",
            dependencies: ["TestKit", "LidSensor", "LidMotion", "FoldRenderer"]
        ),
    ]
)
