// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SimulationCore", products: [.library(name: "SimulationCore", targets: ["SimulationCore"])], targets: [.target(name: "SimulationCore"), .testTarget(name: "SimulationCoreTests", dependencies: ["SimulationCore"])])
