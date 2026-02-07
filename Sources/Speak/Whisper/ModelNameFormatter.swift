import Foundation

enum ModelNameFormatter {
    static func displayName(for filename: String) -> String {
        var name = filename
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
            .replacingOccurrences(of: "-q5_0", with: " (Q5)")
            .replacingOccurrences(of: "-q8_0", with: " (Q8)")
            .replacingOccurrences(of: "-q5_1", with: " (Q5.1)")

        if name.hasSuffix(".en") {
            name = String(name.dropLast(3)) + " English"
        }

        return name.split(separator: "-").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
