import AppKit
import PhiceCore
import Testing
@testable import Phice

private func make() -> (Clipboard, NSPasteboard) {
    let pasteboard = NSPasteboard.withUniqueName()
    let store = ClipStore(directory: tempDirectory())
    return (Clipboard(pasteboard: pasteboard, store: store), pasteboard)
}

@Test func pollingAddsToHistoryOnlyWhenThePasteboardChanged() {
    let (clipboard, pasteboard) = make()
    clipboard.poll()
    #expect(clipboard.store.history.isEmpty)
    pasteboard.clearContents()
    pasteboard.setString("copied on the keyboard", forType: .string)
    clipboard.poll()
    clipboard.poll()
    #expect(clipboard.store.history.map(\.preview) == ["copied on the keyboard"])
    #expect(clipboard.store.pill == nil)
}

@Test func concealedPasteboardContentsAreIgnored() {
    let (clipboard, pasteboard) = make()
    let concealed = NSPasteboard.PasteboardType(concealedType)
    pasteboard.declareTypes([.string, concealed], owner: nil)
    pasteboard.setString("hunter2", forType: .string)
    pasteboard.setData(Data(), forType: concealed)
    clipboard.poll()
    #expect(clipboard.store.history.isEmpty)
    #expect(clipboard.capture(asPill: true) == nil)
    #expect(clipboard.store.pill == nil)
}

@Test func capturingForThePillFillsItAndHistoryOnce() {
    let (clipboard, pasteboard) = make()
    pasteboard.clearContents()
    pasteboard.setString("dropped", forType: .string)
    let item = clipboard.capture(asPill: true)
    clipboard.poll()
    #expect(item?.preview == "dropped")
    #expect(clipboard.store.pill == item)
    #expect(clipboard.store.history == [item!])
}

@Test func pastingWritesEveryTypeBackAndIsNotRecopied() throws {
    let (clipboard, pasteboard) = make()
    let rich: [[String: Data]] = [[
        "public.utf8-plain-text": Data("hello".utf8),
        "public.html": Data("<b>hello</b>".utf8),
    ]]
    let item = try #require(clipboard.store.add(rich, asPill: true))
    #expect(clipboard.write(itemID: item.id))
    let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
    #expect(types.isSuperset(of: ["public.utf8-plain-text", "public.html"]))
    #expect(pasteboard.string(forType: .string) == "hello")
    clipboard.poll()
    #expect(clipboard.store.history.count == 1)
    #expect(!clipboard.write(itemID: "no such item"))
}

@Test func pastingThePillOutEmptiesIt() throws {
    let (clipboard, _) = make()
    let item = try #require(clipboard.store.add(text("held"), asPill: true))
    #expect(clipboard.write(itemID: item.id))
    clipboard.pastedOut(item.id)
    #expect(clipboard.store.pill == nil)
    #expect(clipboard.store.history == [item])
}

@Test func filesKeepOneItemEach() throws {
    let (clipboard, pasteboard) = make()
    let urls = [URL(fileURLWithPath: "/etc/hosts"), URL(fileURLWithPath: "/etc/paths")]
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
    let item = try #require(clipboard.capture(asPill: true))
    #expect(item.kind == .file)
    #expect(item.preview == "hosts and 1 more")
    #expect(clipboard.store.types(for: item.id)?.count == 2)
}
