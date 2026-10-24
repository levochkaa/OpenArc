// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"]),
    ],
    targets: [
        .target(
            name: "ZIPFoundation",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
