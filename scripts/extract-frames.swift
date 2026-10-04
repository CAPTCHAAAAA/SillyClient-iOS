import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 3 else {
    print("Usage: extract-frames <videoPath> <timestampsJsonPath>")
    exit(1)
}

let videoPath = CommandLine.arguments[1]
let jsonPath = CommandLine.arguments[2]

let videoURL = URL(fileURLWithPath: videoPath)
let jsonURL = URL(fileURLWithPath: jsonPath)

guard FileManager.default.fileExists(atPath: videoPath) else {
    print("[Extractor] Video file not found: \(videoPath)")
    exit(1)
}

guard let data = try? Data(contentsOf: jsonURL),
      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    print("[Extractor] Timestamps JSON file not found or invalid: \(jsonPath)")
    exit(1)
}

let asset = AVAsset(url: videoURL)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let outputDir = videoURL.deletingLastPathComponent()
print("[Extractor] Extracting \(items.count) step frames from \(videoURL.lastPathComponent)...")

var extractedCount = 0

for item in items {
    guard let name = item["name"] as? String,
          let timeSec = item["time"] as? Double else { continue }
    
    // Ensure timeSec is within asset duration
    let cmTime = CMTime(seconds: max(0.1, timeSec), preferredTimescale: 600)
    do {
        let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
        let outURL = outputDir.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("[Extractor] Failed to create CGImageDestination for \(name)")
            continue
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if CGImageDestinationFinalize(dest) {
            extractedCount += 1
            print("[Extractor] [\(extractedCount)/\(items.count)] Saved \(name).png @ \(String(format: "%.2f", timeSec))s")
        } else {
            print("[Extractor] Failed to finalize \(name).png")
        }
    } catch {
        print("[Extractor] Error extracting \(name) at \(timeSec)s: \(error.localizedDescription)")
    }
}

print("[Extractor] Frame extraction completed successfully: \(extractedCount) / \(items.count) frames saved.")
