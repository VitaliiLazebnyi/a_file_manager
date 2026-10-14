import Foundation
import FuzzCore

/// The bytes as text; bytes that are no UTF-8 become U+FFFD (`fzText`).
internal func text(_ bytes: [UInt8]) -> String {
    fzText(bytes)
}

/// Seed inputs given as text.
internal func seedTexts(_ texts: [String]) -> [[UInt8]] {
    texts.map { Array($0.utf8) }
}

/// A URL written in the driver itself; a typing error in it is a bug of the driver.
internal func fixedURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("not a URL: \(string)")
    }
    return url
}
