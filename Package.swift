// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnersCore",
    platforms: [.macOS(.v13), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "RunnersCore", targets: ["RunnersCore"]),
               .library(name: "RunnersPhoneCore", targets: ["RunnersPhoneCore"])],
    targets: [
        .target(name: "RunnersCore", path: "RunnersWatch/Core"),
        .target(name: "RunnersPhoneCore", path: "Shared/Core"),
        .testTarget(name: "RunnersCoreTests", dependencies: ["RunnersCore"], path: "Tests/RunnersCoreTests"),
        .testTarget(name: "RunnersPhoneCoreTests", dependencies: ["RunnersPhoneCore"], path: "Tests/RunnersPhoneCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
