// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TheBrowserDependencies",
    platforms: [
        .macOS(.v14),
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/Dashlane/SwiftDomainParser.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "TheBrowserDependencies",
            dependencies: [
                .product(name: "DomainParser", package: "SwiftDomainParser"),
            ],
            path: "Support/SPMDependencies"
        ),
    ]
)
