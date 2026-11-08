// swift-tools-version: 5.9
import PackageDescription

// llama.cpp (MIT license, github.com/ggml-org/llama.cpp) as Apple's prebuilt XCFramework.
// Phonodeck uses it to run GGUF storyteller models, which MLX can't load.
// To update: pick a newer release tag, change both lines, and set the checksum to
// `shasum -a 256 llama-<tag>-xcframework.zip`.
let package = Package(
    name: "LlamaFramework",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LlamaFramework", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12211/llama-b12211-xcframework.zip",
            checksum: "1f701c47b0e2f9410e1441960105e7d7ad1757f8a49e4063c6e792df31348a7a"),
    ]
)
