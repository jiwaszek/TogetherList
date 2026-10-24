// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TogetherListKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TogetherListCore", targets: ["TogetherListCore"]),
        .library(name: "TogetherListSupabase", targets: ["TogetherListSupabase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
    ],
    targets: [
        // Domain models, backend protocol, offline sync engine. No third-party deps.
        .target(name: "TogetherListCore"),
        // Supabase implementation of `BackendService`.
        .target(
            name: "TogetherListSupabase",
            dependencies: [
                "TogetherListCore",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "TogetherListCoreTests", dependencies: ["TogetherListCore"]),
    ]
)
