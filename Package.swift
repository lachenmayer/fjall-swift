// swift-tools-version:6.0
import Foundation
import PackageDescription

// The Rust core (fjall + the UniFFI bridge) is provided as:
//
// - Apple platforms: a prebuilt `FjallFFI.xcframework`.
//   - By default, a prebuilt framework from a GitHub release is used.
//   - Set `FJALL_USE_LOCAL_FRAMEWORK=1` to use a locally built framework
//     (build it with `scripts/build-xcframework.sh`).
// - Linux: a system-library target. Build the static library with
//   `cargo build --release --manifest-path rust/Cargo.toml` and pass its
//   location to SwiftPM, e.g.
//   `swift build -Xlinker -Lrust/target/release`.

let ffiTarget: Target

#if os(Linux)
ffiTarget = .systemLibrary(
    name: "CFjallFFI",
    path: "Sources/CFjallFFI"
)
#else
// NOTE: url + checksum are rewritten by the release workflow
// (see .github/workflows/release.yml) whenever a version is tagged.
let releaseURL = "https://github.com/lachenmayer/fjall-swift/releases/download/v0.1.1/FjallFFI.xcframework.zip"
let releaseChecksum = "db77a8b8e96fb07752c493be791a2453120e1e8f38862ea8dd29af846c6c6968"

let useLocalFramework =
    ProcessInfo.processInfo.environment["FJALL_USE_LOCAL_FRAMEWORK"] != nil
    || releaseURL.hasPrefix("FJALL_")  // no release has been tagged yet

if useLocalFramework {
    ffiTarget = .binaryTarget(
        name: "CFjallFFI",
        path: "rust/target/xcframework/FjallFFI.xcframework"
    )
} else {
    ffiTarget = .binaryTarget(
        name: "CFjallFFI",
        url: releaseURL,
        checksum: releaseChecksum
    )
}
#endif

let package = Package(
    name: "fjall-swift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Fjall", targets: ["Fjall"])
    ],
    targets: [
        ffiTarget,
        // Generated UniFFI bindings (regenerate with scripts/generate-bindings.sh).
        .target(
            name: "FjallFFI",
            dependencies: ["CFjallFFI"],
            path: "Sources/FjallFFI"
        ),
        // The hand-written, Swift-y public API.
        .target(
            name: "Fjall",
            dependencies: ["FjallFFI"],
            path: "Sources/Fjall"
        ),
        .testTarget(
            name: "FjallTests",
            dependencies: ["Fjall"],
            path: "Tests/FjallTests"
        ),
    ]
)
