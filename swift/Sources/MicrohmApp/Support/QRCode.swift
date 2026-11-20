import AppKit
import CoreImage

/// QR codes for a phone camera to read off the screen (Java's `QrImages`): black on white
/// whatever the theme — cameras need the contrast — with the standard 4-module quiet zone.
enum QRCode {
    static let border = 4

    static func image(_ text: String, scale: Int) -> NSImage? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let modules = Int(output.extent.width)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        let side = (modules + border * 2) * scale
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.interpolationQuality = .none
            let inset = CGFloat(border * scale)
            ctx.draw(cg, in: CGRect(x: inset, y: inset, width: CGFloat(modules * scale), height: CGFloat(modules * scale)))
            return true
        }
        image.accessibilityDescription = "QR code for \(text)"
        return image
    }
}

