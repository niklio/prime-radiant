// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrimeRadiantCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PrimeRadiantCore", targets: ["PrimeRadiantCore"])
    ],
    dependencies: [
        // The macOS Command Line Tools ship no usable swift-testing modules, so we
        // build it from source, pinned to the toolchain's release tag. Under full
        // Xcode this dependency shadows the bundled copy harmlessly.
        // Tag swift-6.2.4-RELEASE (tags aren't semver, so pin the revision).
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170")
    ],
    targets: [
        .target(name: "PrimeRadiantCore"),
        .testTarget(
            name: "PrimeRadiantCoreTests",
            dependencies: [
                "PrimeRadiantCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        )
    ]
)
