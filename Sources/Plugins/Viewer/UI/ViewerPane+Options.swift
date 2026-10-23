import AFMKernel
import CoreFoundation
import Foundation

/// The Options and Encoding menus: the font, the encoding, the zoom and the fitting of images.
extension ViewerPane {
    /// Options › ANSI, ASCII, Variable: the font and, with it, the character set.
    internal func setFontSlot(_ slot: FontSlot) {
        fontSlot = slot
        codePage = nil
        if mode == .html {
            // The tags of an HTML file are removed from its bytes: with the new encoding.
            redecodeHTML()
            present()
            return
        }
        relayout()
    }

    /// The Encoding menu: a code page for text mode, or one of the Unicode modes.
    internal func setEncoding(_ encoding: ViewerEncoding?) {
        guard loaded != nil else {
            return
        }
        switch encoding?.kind {
        case .utf8:
            mode = .utf8

        case .utf16LE, .utf16BE:
            codePage = encoding
            mode = .unicode

        default:
            codePage = encoding
            if mode == .utf8 || mode == .unicode { mode = .text }
        }
        redecodeHTML()
        present()
    }

    /// "Other (enter code page manually)": a number is used for now, `Name (number)` is also
    /// added to the menu (spec 10 › Encoding menu).
    internal func askForCodePage() {
        guard
            let answer = kernel.interaction.prompt(
                "Code page",
                value: "",
                detail: "A number such as 866, or \"Name (866)\" to keep it in the menu."
            )
        else { return }
        let digits =
            answer.contains("(")
            ? answer.split(separator: "(").last.map { $0.prefix(while: \.isNumber) }.map(String.init) ?? "" : answer
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)),
            let encoding = ViewerEncoding.codePage(number)
        else {
            kernel.interaction.inform("The code page \(answer) is not available on this Mac.")
            return
        }
        if answer.contains("("), !settings.userCodePages.contains(number) { settings.userCodePages.append(number) }
        setEncoding(encoding)
    }

    /// Larger (+1), Smaller (-1), Actual size (0): the zoom of an image, else the size of the font.
    internal func zoom(_ direction: Int) {
        if let imageView {
            imageView.setZoom(direction == 0 ? 1 : imageView.zoom * (direction > 0 ? 1.25 : 0.8))
        } else {
            changeFontSize(by: Double(direction))
        }
    }

    /// The fit entries: `fit` on, or off again when it is on; for a film, fit or fill the window.
    internal func toggleFit(_ fit: ImageFit) {
        if let mediaView {
            mediaView.toggleFit()
            return
        }
        settings.imageFit = settings.imageFit == fit ? .actualSize : fit
        imageView?.fit = settings.imageFit
    }
}
