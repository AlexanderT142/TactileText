import Foundation

enum MockSemantics {
    static let document: SemanticDocument = {
        do {
            let raw = try JSONDecoder().decode(RawSemanticDocument.self, from: Data(payload.utf8))
            var document = raw.toSemanticDocument()
            try document.resolveWordRangesSequentially()
            return document
        } catch {
            fatalError("Failed to decode mock semantics: \(error)")
        }
    }()

    private static let payload = """
    {
      "id": "36D6D1DD-E0FA-4678-A9E5-DB93416F89AD",
      "text": "The magnetic cursor drifts over the paragraph, and each word decides whether your attention is precise, contextual, or panoramic. When the hand steadies, the language rises like paper tiles with real mass, and the surrounding sentence softens into peripheral blur. The interaction should feel calm enough that the interface seems to predict intent before any click is required.",
      "sentences": [
        {
          "id": "508D3878-9C45-4A7D-B8D9-6A65C2EF4AA2",
          "phrases": [
            {
              "id": "4D8F6458-B0CE-4D56-B74C-67E08E0B9BEE",
              "words": ["The", "magnetic", "cursor"]
            },
            {
              "id": "F0B0E3CF-64D0-49F3-8ABF-58F53A00D1C4",
              "words": ["drifts", "over", "the", "paragraph,"]
            },
            {
              "id": "8E46F194-0860-458D-8E9E-26FB616DE08B",
              "words": ["and", "each", "word", "decides"]
            },
            {
              "id": "3FD4846A-7DCA-41C9-9A51-2C41135F2A59",
              "words": ["whether", "your", "attention", "is", "precise,", "contextual,", "or", "panoramic."]
            }
          ]
        },
        {
          "id": "470B322A-C6B8-41DE-9308-ECC60CB5C2F8",
          "phrases": [
            {
              "id": "DF0D39DE-7C58-40D6-BFD7-F96A615648A4",
              "words": ["When", "the", "hand", "steadies,"]
            },
            {
              "id": "2B3543D8-3D72-4A8F-A5D5-3D9D86BCA430",
              "words": ["the", "language", "rises", "like", "paper", "tiles"]
            },
            {
              "id": "A6E4E9D3-3D1D-4B47-A141-B718F8F9A4BC",
              "words": ["with", "real", "mass,", "and", "the", "surrounding", "sentence"]
            },
            {
              "id": "B8487756-A7D9-4E6B-83C2-9BC1A5EEA59A",
              "words": ["softens", "into", "peripheral", "blur."]
            }
          ]
        },
        {
          "id": "94DA8189-9E14-4125-BB57-EAD6CF8698D4",
          "phrases": [
            {
              "id": "E4198FCD-00E7-4EC8-8F24-B14A70F3CA95",
              "words": ["The", "interaction", "should", "feel", "calm", "enough"]
            },
            {
              "id": "A2B6D72F-F727-4EA3-AE67-D5510A56D72E",
              "words": ["that", "the", "interface", "seems", "to", "predict", "intent"]
            },
            {
              "id": "6A989D63-A1D5-4E5E-8AA5-2E39B11E3DC8",
              "words": ["before", "any", "click", "is", "required."]
            }
          ]
        }
      ]
    }
    """
}

private struct RawSemanticDocument: Decodable {
    let id: UUID
    let text: String
    let sentences: [RawSemanticSentence]

    func toSemanticDocument() -> SemanticDocument {
        SemanticDocument(
            id: id,
            text: text,
            sentences: sentences.map { $0.toSemanticSentence() }
        )
    }
}

private struct RawSemanticSentence: Decodable {
    let id: UUID
    let phrases: [RawSemanticPhrase]

    func toSemanticSentence() -> SemanticSentence {
        SemanticSentence(
            id: id,
            phrases: phrases.map { $0.toSemanticPhrase() }
        )
    }
}

private struct RawSemanticPhrase: Decodable {
    let id: UUID
    let words: [String]

    func toSemanticPhrase() -> SemanticPhrase {
        SemanticPhrase(
            id: id,
            words: words.map {
                SemanticWord(
                    id: UUID(),
                    text: $0,
                    range: SemanticRange(location: 0, length: 0)
                )
            }
        )
    }
}
