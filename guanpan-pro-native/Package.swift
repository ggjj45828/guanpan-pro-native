// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GuanpanResearchCore",
    products: [.library(name: "GuanpanResearchCore", targets: ["GuanpanResearchCore"])],
    targets: [
        .target(name: "GuanpanResearchCore", path: "Sources", sources: ["PaperTrading.swift", "CostOverlayDomain.swift"]),
        .testTarget(name: "GuanpanResearchCoreTests", dependencies: ["GuanpanResearchCore"], path: "Tests/Core")
    ]
)
