import Foundation
import Vision

// Offline OCR only. This command reads owned image copies, never a screen/window.
struct ImageInput: Decodable { let id: String; let file: String }
struct ImageResult: Encodable { let id: String; let lines: [String]; let error: String? }
let args = CommandLine.arguments
precondition(args.count == 3, "PrivacyImages MANIFEST OUTPUT")
let inputs = try JSONDecoder().decode([ImageInput].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
FileManager.default.createFile(atPath: args[2], contents: nil)
let output = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
for input in inputs {
    let result = autoreleasepool { () -> ImageResult in
        do {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.usesCPUOnly = true
            try VNImageRequestHandler(url: URL(fileURLWithPath: input.file), options: [:]).perform([request])
            return ImageResult(id: input.id, lines: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }, error: nil)
        } catch { return ImageResult(id: input.id, lines: [], error: String(describing: error)) }
    }
    try output.write(contentsOf: JSONEncoder().encode(result)); try output.write(contentsOf: Data([10]))
}
try output.close()
