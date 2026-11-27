// swift-tools-version: 6.2

import PackageDescription

// A path dependency is named after its directory, which is whatever the checkout is called.
let mimalloc = Context.packageDirectory.split(separator: "/").dropLast(3).last.map(String.init) ?? "mimalloc"

// Depends on the mimalloc package the way an application does, passing its traits through.
let package = Package(
    name: "test-override",
    platforms: [.macOS(.v15)],
    traits: [
        .default(enabledTraits: ["Override"]),
        .trait(name: "Override"),
        .trait(name: "LocalDynamicTLS"),
    ],
    dependencies: [
        .package(
            path: "../../..",
            traits: [
                .trait(name: "Override", condition: .when(traits: ["Override"])),
                .trait(name: "LocalDynamicTLS", condition: .when(traits: ["LocalDynamicTLS"])),
            ]
        ),
    ],
    targets: [
        .executableTarget(
            name: "test-override",
            dependencies: [.product(name: "mimalloc", package: mimalloc)]
        ),
    ]
)
