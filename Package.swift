// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OneloSwift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OneloSwift", targets: ["OneloSwift"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/supabase/supabase-swift",
            from: "2.0.0"
        ),
    ],
    targets: [
        .target(
            name: "OneloSwift",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "OneloSwiftTests",
            dependencies: ["OneloSwift"]
        ),
    ]
)
