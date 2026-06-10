// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "TheBrowserDependencies",
    platforms: [
        .macOS(.v14),
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/1024jp/GzipSwift.git", exact: "7.0.0"),
        .package(url: "https://github.com/Dashlane/SwiftDomainParser.git", exact: "1.1.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", exact: "1.3.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.15.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/sindresorhus/Settings.git", exact: "3.1.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "TheBrowserDependencies",
            dependencies: [
                .product(name: "DomainParser", package: "SwiftDomainParser"),
                .product(name: "Gzip", package: "GzipSwift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Support/SPMDependencies"
        ),
    ]
)
