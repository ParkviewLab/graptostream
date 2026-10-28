// swift-tools-version: 6.2
// The package builds the app's executable and its testable core; build.sh
// assembles and signs Graptostream.app from the executable. Apple frameworks only.

import PackageDescription

let package = Package(
    name: "graptostream",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Graptostream", targets: ["Graptostream"]),
    ],
    targets: [
        .target(name: "GraptostreamCore"),
        .executableTarget(name: "Graptostream", dependencies: ["GraptostreamCore"]),
        .testTarget(name: "GraptostreamCoreTests", dependencies: ["GraptostreamCore"]),
    ]
)
