import Accelerate
import Foundation

enum Seam {
    static let context = 2 * Recognizer.rate

    private static let search = 4 * Recognizer.rate
    private static let quietFrames = 2

    static func cut(_ samples: [Float], after tokens: [Token], before end: Int) -> Int {
        let range = end - context - search ..< end - context
        let gaps = zip(tokens, tokens.dropFirst())
            .filter { previous, next in next.startsWord && !previous.isPunctuation }
            .map { previous, next in (cut: (previous.position + next.position) / 2, width: next.position - previous.position) }
            .filter { range.contains($0.cut) }
        return gaps.max { $0.width < $1.width }?.cut ?? quietest(samples, in: range)
    }

    private static func quietest(_ samples: [Float], in range: Range<Int>) -> Int {
        let frame = Recognizer.samplesPerFrame
        let energy = stride(from: range.lowerBound, to: range.upperBound - frame, by: frame).map {
            vDSP.sumOfSquares(samples[$0 ..< $0 + frame])
        }
        let quiet = { (boundary: Int) in energy[boundary - quietFrames ..< boundary + quietFrames].reduce(0, +) }
        let boundary = (quietFrames ... energy.count - quietFrames).min { quiet($0) < quiet($1) } ?? energy.count / 2
        return range.lowerBound + boundary * frame
    }
}

struct Token {
    let piece: String
    let position: Int

    var startsWord: Bool { piece.hasPrefix("▁") }
    var isPunctuation: Bool { !piece.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
}
