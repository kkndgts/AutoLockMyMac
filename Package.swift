// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AutoLockMyMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AutoLockMyMac", targets: ["AutoLockMyMac"])
    ],
    targets: [
        .executableTarget(
            name: "AutoLockMyMac",
            exclude: [
                "Assets"
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .testTarget(
            name: "AutoLockMyMacTests",
            dependencies: ["AutoLockMyMac"]
        )
    ],
    swiftLanguageModes: [.v6]
)
