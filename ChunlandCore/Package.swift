// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChunlandCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ChunlandCore", targets: ["ChunlandCore"]),
    ],
    targets: [
        .target(
            name: "ChunlandCore",
            path: "Sources/ChunlandCore"
        ),
    ]
)
