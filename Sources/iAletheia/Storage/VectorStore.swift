import Foundation
import NaturalLanguage
import Accelerate

final class VectorStore {
    private var vectors: [UUID: [Float]] = [:]
    private let embeddingDimension = 384

    func upsert(memoryID: UUID, embedding: [Float]) {
        vectors[memoryID] = embedding
    }

    func remove(memoryID: UUID) {
        vectors.removeValue(forKey: memoryID)
    }

    func clear() {
        vectors.removeAll()
    }

    func search(query: String, limit: Int = 10) -> [(UUID, Double)] {
        let queryVector = embed(text: query)
        var results: [(UUID, Double)] = []
        for (id, vector) in vectors {
            let score = cosineSimilarity(queryVector, vector)
            results.append((id, score))
        }
        return results.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    func embed(text: String) -> [Float] {
        if let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english) {
            let vector = sentenceEmbedding.vector(for: text) ?? []
            if !vector.isEmpty {
                return normalize(Array(vector.prefix(embeddingDimension)).map(Float.init))
            }
        }
        return fallbackHashEmbedding(text: text)
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(count))
        let denom = sqrt(normA * normB)
        guard denom > 0 else { return 0 }
        return Double(dot / denom)
    }

    private func normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        var scaled = vector
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &scaled, 1, vDSP_Length(vector.count))
        return scaled
    }

    private func fallbackHashEmbedding(text: String) -> [Float] {
        var result = [Float](repeating: 0, count: embeddingDimension)
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            let hash = abs(token.hashValue) % embeddingDimension
            result[hash] += 1
        }
        return normalize(result)
    }
}
