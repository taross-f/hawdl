// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hawdl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HawdlCore", targets: ["HawdlCore"]),
        .executable(name: "hawdld", targets: ["hawdld"]),
        .executable(name: "hawdl", targets: ["hawdl"]),
        .executable(name: "HawdlBar", targets: ["HawdlBar"]),
    ],
    targets: [
        // Thin C shim. Everything in here exists because Swift cannot import
        // the pieces of <sys/ioctl.h> / <net/if.h> / <net/route.h> that we need:
        // SIOCGIFFLAGS and SIOCSIFFLAGS are computed by the _IOWR()/_IOW()
        // function-like macros, ioctl(2) is C-variadic, and struct ifreq's
        // anonymous union does not import reliably. This is not an external
        // dependency: it is part of this package.
        .target(name: "CHawdlSys"),

        .target(name: "HawdlCore", dependencies: ["CHawdlSys"]),

        .executableTarget(name: "hawdld", dependencies: ["HawdlCore"]),
        .executableTarget(name: "hawdl", dependencies: ["HawdlCore"]),
        .executableTarget(
            name: "HawdlBar",
            dependencies: ["HawdlCore"],
            // Info.plist is consumed by the .app bundle assembly in the
            // Homebrew formula, not by SwiftPM.
            exclude: ["Resources/Info.plist"]
        ),

        .testTarget(name: "HawdlCoreTests", dependencies: ["HawdlCore"]),
    ]
)
