// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GuanpanAdvisorCore", platforms: [.iOS(.v17), .macOS(.v10_15)], products: [.library(name: "GuanpanAdvisorCore", targets: ["GuanpanAdvisorCore"])], targets: [
    .target(name: "GuanpanAdvisorCore", path: "Sources", sources: ["NextCore.swift", "LocalRules.swift", "GlobalIndices.swift", "PortfolioSummary.swift", "InstrumentCatalog.swift", "NextAIGuide.swift", "NextCandidatePlans.swift", "NextDecisionMemory.swift", "NextNewsImpact.swift", "InvestorProfile.swift", "AppThemeCore.swift", "MarketDataSources.swift"]),
    .testTarget(name: "GuanpanAdvisorCoreTests", dependencies: ["GuanpanAdvisorCore"], path: "Tests")
])
