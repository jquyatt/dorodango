// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dorodango",
    platforms: [
        .macOS(.v13) // MenuBarExtra requires macOS 13 Ventura or later
    ],
    targets: [
        .executableTarget(
            name: "Dorodango",
            path: "Sources/Dorodango"
        )
    ]
)
