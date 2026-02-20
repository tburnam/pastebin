import Foundation

struct Bucket: Identifiable, Equatable {
    let id: Int64
    let name: String
    let colorHex: String
}

struct BucketColorOption: Identifiable, Equatable {
    let id: String
    let name: String
    let hex: String

    init(name: String, hex: String) {
        self.id = hex
        self.name = name
        self.hex = hex
    }
}

enum BucketDefaults {
    static let defaultName = "Untitled"
    static let defaultColorHex = "#FF4747"

    static let colorPalette: [BucketColorOption] = [
        BucketColorOption(name: "Red", hex: "#FF4747"),
        BucketColorOption(name: "Orange", hex: "#FF9D2F"),
        BucketColorOption(name: "Yellow", hex: "#F2C41B"),
        BucketColorOption(name: "Green", hex: "#45CC5A"),
        BucketColorOption(name: "Blue", hex: "#2390F5"),
        BucketColorOption(name: "Purple", hex: "#C73AF0"),
        BucketColorOption(name: "Pink", hex: "#FF4F7A"),
        BucketColorOption(name: "Gray", hex: "#A4A8AF")
    ]
}
