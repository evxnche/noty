import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Photos are copied beside the database; note bodies keep relative Markdown links.
enum Photos {
    static func save(_ data: Data, extension ext: String, directory: URL = Paths.support) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw NSError(domain: "Noty", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file is not a readable image."])
        }
        let safeExtension = ext.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
        let name = "photo-\(UUID().uuidString).\(safeExtension.isEmpty ? "png" : safeExtension)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "![Photo](\(name))"
    }

    static func names(in text: String) -> [String] {
        let pattern = #"!\[Photo\]\((photo-[A-Fa-f0-9-]+\.[a-z0-9]+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let name = ns.substring(with: $0.range(at: 1))
            return seen.insert(name).inserted ? name : nil
        }
    }

    static func thumbnail(_ name: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(Paths.support.appendingPathComponent(name) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

extension TaskTextView {
    func insertPhotos(_ urls: [URL]) {
        do {
            for url in urls {
                let link = try Photos.save(Data(contentsOf: url), extension: url.pathExtension)
                insertText("\n" + link + "\n", replacementRange: selectedRange())
            }
        } catch { NSAlert(error: error).runModal() }
    }

    func choosePhotos() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.title = "Add photos"
        if picker.runModal() == .OK { insertPhotos(picker.urls) }
        window?.makeFirstResponder(self)
    }
}
