import Foundation

struct SearchFingerprint {
    private let bytePresence0: UInt64
    private let bytePresence1: UInt64
    private let bytePresence2: UInt64
    private let bytePresence3: UInt64

    init(bytes: ContiguousArray<UInt8>) {
        var bytePresence = [UInt64](repeating: 0, count: 4)
        for byte in bytes {
            let byteValue = Int(byte)
            bytePresence[byteValue >> 6] |= (1 as UInt64) << UInt64(byteValue & 63)
        }

        bytePresence0 = bytePresence[0]
        bytePresence1 = bytePresence[1]
        bytePresence2 = bytePresence[2]
        bytePresence3 = bytePresence[3]
    }

    @inline(__always)
    func containsAllBytes(_ needle: ContiguousArray<UInt8>) -> Bool {
        for byte in needle {
            let byteValue = Int(byte)
            let wordMask = (1 as UInt64) << UInt64(byteValue & 63)
            let word: UInt64
            switch byteValue >> 6 {
            case 0:
                word = bytePresence0
            case 1:
                word = bytePresence1
            case 2:
                word = bytePresence2
            default:
                word = bytePresence3
            }

            if (word & wordMask) == 0 {
                return false
            }
        }

        return true
    }

    @inline(__always)
    func mayContainContiguousSequence(_ needle: ContiguousArray<UInt8>) -> Bool { true }
}
