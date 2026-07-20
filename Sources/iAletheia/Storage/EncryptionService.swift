import Foundation
import CryptoKit

final class EncryptionService {
    func encrypt(_ data: Data, using key: SymmetricKey) -> Data {
        (try? AES.GCM.seal(data, using: key).combined) ?? data
    }

    func decrypt(_ data: Data, using key: SymmetricKey) -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let decrypted = try? AES.GCM.open(box, using: key) else { return data }
        return decrypted
    }
}
