import Foundation
import ImageIO
import PhiceCore
import Testing
@testable import Phice

@Test func textBecomesATrimmedSnippet() {
    let long = String(repeating: "word ", count: 100)
    let s = ClipPreview.summary(of: text("  first line\n\n   second\tline  "))
    #expect(s?.kind == .text)
    #expect(s?.preview == "first line second line")
    #expect(ClipPreview.summary(of: text(long))?.preview.count == 200)
}

@Test func aLoneWebAddressIsALink() {
    #expect(ClipPreview.summary(of: text("https://example.com/a?b=1"))?.kind == .link)
    #expect(ClipPreview.summary(of: text("see https://example.com"))?.kind == .text)
    let url: [[String: Data]] = [["public.url": Data("https://example.com".utf8)]]
    #expect(ClipPreview.summary(of: url)?.kind == .link)
    #expect(ClipPreview.summary(of: url)?.preview == "https://example.com")
}

@Test func filesShowTheirNames() {
    let one: [[String: Data]] = [["public.file-url": Data("file:///Users/me/My%20Report.pdf".utf8)]]
    #expect(ClipPreview.summary(of: one)?.kind == .file)
    #expect(ClipPreview.summary(of: one)?.preview == "My Report.pdf")
    let three = one + one + one
    #expect(ClipPreview.summary(of: three)?.preview == "My Report.pdf and 2 more")
}

@Test func filesWinOverTheTextFinderAlsoWrites() {
    let both: [[String: Data]] = [[
        "public.file-url": Data("file:///a/b.txt".utf8),
        "public.utf8-plain-text": Data("b.txt".utf8),
    ]]
    #expect(ClipPreview.summary(of: both)?.kind == .file)
}

@Test func imagesGetAThumbnailNoBiggerThan128Points() throws {
    let big = png(width: 400, height: 200)
    let s = try #require(ClipPreview.summary(of: [["public.png": big]]))
    #expect(s.kind == .image)
    let thumb = try #require(s.thumbnail)
    let source = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(image.width, image.height) == 128)
    #expect(image.height == 64)
}

@Test func smallImagesAreNotEnlarged() throws {
    let s = try #require(ClipPreview.summary(of: [["public.png": png(width: 40, height: 20)]]))
    let source = CGImageSourceCreateWithData(try #require(s.thumbnail) as CFData, nil)!
    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 40)
}

@Test func unknownTypesStillGetAnEntryAndEmptyOnesDoNot() {
    #expect(ClipPreview.summary(of: [["com.example.private": Data([1])]])?.kind == .text)
    #expect(ClipPreview.summary(of: []) == nil)
    #expect(ClipPreview.summary(of: [[:]]) == nil)
}

@Test func concealedMarkersAreFoundOnAnyItem() {
    #expect(ClipPreview.isConcealed([["public.utf8-plain-text": Data(), concealedType: Data()]]))
    #expect(ClipPreview.isConcealed(text("a") + [[transientType: Data()]]))
    #expect(!ClipPreview.isConcealed(text("a")))
}

@Test func shortcutInputIsTheCopiedItemAsAFile() throws {
    let dir = tempDirectory()
    let file = try #require(ShortcutInput.file(for: text("hello"), in: dir))
    #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
    #expect(file.pathExtension == "txt")
    let existing: [[String: Data]] = [["public.file-url": Data("file:///etc/hosts".utf8)]]
    #expect(ShortcutInput.file(for: existing, in: dir)?.path == "/etc/hosts")
    let picture: [[String: Data]] = [["public.png": png(width: 8, height: 8)]]
    let image = try #require(ShortcutInput.file(for: picture, in: dir))
    #expect(image.pathExtension == "png")
}

@Test func shortcutListsParseOnePerLine() {
    let listed = ShortcutsCLI.parse("Resize Image\n\n  Upload  \nQuick Note\n")
    #expect(listed == ["Resize Image", "Upload", "Quick Note"])
    #expect(ShortcutsCLI.parse("").isEmpty)
}
