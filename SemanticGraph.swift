import Foundation
import CoreGraphics

enum SemanticDocumentError: Error {
    case tokenNotFound(String)
}

struct SemanticRange: Codable, Equatable {
    var location: Int
    var length: Int

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    var upperBound: Int {
        location + length
    }
}

struct SemanticWord: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    var range: SemanticRange
    private var resolvedFrame: CGRect? = nil

    init(id: UUID, text: String, range: SemanticRange) {
        self.id = id
        self.text = text
        self.range = range
        resolvedFrame = nil
    }

    var frame: CGRect {
        resolvedFrame ?? .zero
    }

    mutating func applyFrame(_ frame: CGRect?) {
        resolvedFrame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case range
    }
}

struct SemanticPhrase: Identifiable, Codable, Equatable {
    let id: UUID
    var words: [SemanticWord]

    var frame: CGRect {
        unionFrame(words.map(\.frame))
    }
}

struct SemanticSentence: Identifiable, Codable, Equatable {
    let id: UUID
    var phrases: [SemanticPhrase]

    var frame: CGRect {
        unionFrame(phrases.map(\.frame))
    }
}

struct SemanticDocument: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    var sentences: [SemanticSentence]

    var frame: CGRect {
        unionFrame(sentences.map(\.frame))
    }

    var wordsInReadingOrder: [SemanticWord] {
        var result: [SemanticWord] = []
        result.reserveCapacity(sentences.reduce(0) { partial, sentence in
            partial + sentence.phrases.reduce(0) { $0 + $1.words.count }
        })

        for sentence in sentences {
            for phrase in sentence.phrases {
                result.append(contentsOf: phrase.words)
            }
        }

        return result
    }

    mutating func resolveWordRangesSequentially() throws {
        let textNSString = text as NSString
        var cursor = 0

        for sentenceIndex in sentences.indices {
            for phraseIndex in sentences[sentenceIndex].phrases.indices {
                for wordIndex in sentences[sentenceIndex].phrases[phraseIndex].words.indices {
                    let token = sentences[sentenceIndex].phrases[phraseIndex].words[wordIndex].text
                    let searchRange = NSRange(location: cursor, length: max(0, textNSString.length - cursor))
                    let foundRange = textNSString.range(of: token, options: [], range: searchRange)

                    guard foundRange.location != NSNotFound else {
                        throw SemanticDocumentError.tokenNotFound(token)
                    }

                    sentences[sentenceIndex].phrases[phraseIndex].words[wordIndex].range = SemanticRange(
                        location: foundRange.location,
                        length: foundRange.length
                    )

                    cursor = foundRange.upperBound
                }
            }
        }
    }

    mutating func applyWordFrames(_ frames: [UUID: CGRect]) {
        for sentenceIndex in sentences.indices {
            for phraseIndex in sentences[sentenceIndex].phrases.indices {
                for wordIndex in sentences[sentenceIndex].phrases[phraseIndex].words.indices {
                    let wordID = sentences[sentenceIndex].phrases[phraseIndex].words[wordIndex].id
                    sentences[sentenceIndex].phrases[phraseIndex].words[wordIndex].applyFrame(frames[wordID])
                }
            }
        }
    }
}

private func unionFrame(_ rects: [CGRect]) -> CGRect {
    var union = CGRect.null
    for rect in rects where !rect.isNull && !rect.isEmpty {
        union = union.union(rect)
    }
    return union.isNull ? .zero : union
}

private extension NSRange {
    var upperBound: Int {
        location + length
    }
}
