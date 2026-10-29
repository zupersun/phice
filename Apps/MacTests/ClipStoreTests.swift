import Foundation
import PhiceCore
import Testing
@testable import Phice

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func concealedAndTransientItemsAreNeverStored() {
    let dir = tempDirectory()
    let store = ClipStore(directory: dir)
    for marker in [concealedType, transientType] {
        var item = text("hunter2")
        item[0][marker] = Data()
        #expect(store.add(item, asPill: true, now: t0) == nil)
    }
    #expect(store.history.isEmpty)
    #expect(store.pill == nil)
    #expect(everythingWritten(under: dir).range(of: Data("hunter2".utf8)) == nil)
}

@Test func historyIsCappedAtFifty() {
    let dir = tempDirectory()
    let store = ClipStore(directory: dir)
    for i in 0..<60 { store.add(text("item \(i)"), now: t0.addingTimeInterval(Double(i))) }
    #expect(store.history.count == 50)
    #expect(store.history.first?.preview == "item 59")
    #expect(store.history.last?.preview == "item 10")
    let folder = dir.appendingPathComponent("blobs").path
    let blobs = try? FileManager.default.contentsOfDirectory(atPath: folder)
    #expect(blobs?.count == 50)
}

@Test func itemsExpireAfterSevenDays() {
    let dir = tempDirectory()
    let store = ClipStore(directory: dir)
    store.add(text("old"), now: t0)
    store.add(text("new"), now: t0.addingTimeInterval(6 * 86400))
    store.prune(now: t0.addingTimeInterval(8 * 86400))
    #expect(store.history.map(\.preview) == ["new"])
    let later = t0.addingTimeInterval(8 * 86400)
    #expect(ClipStore(directory: dir, now: later).history.map(\.preview) == ["new"])
}

@Test func theItemInThePillOutlivesExpiryAndTheCap() {
    let store = ClipStore(directory: tempDirectory())
    let held = store.add(text("held"), asPill: true, now: t0)
    for i in 0..<60 { store.add(text("later \(i)"), now: t0.addingTimeInterval(Double(i + 1))) }
    store.prune(now: t0.addingTimeInterval(30 * 86400))
    #expect(store.history.contains { $0.id == held?.id })
    #expect(store.pill?.id == held?.id)
}

@Test func thePillSurvivesARestartWithEveryType() {
    let dir = tempDirectory()
    let items: [[String: Data]] = [[
        "public.utf8-plain-text": Data("hello".utf8),
        "public.html": Data("<b>hello</b>".utf8),
        "com.example.private": Data([1, 2, 3, 0xFF]),
    ]]
    let held = ClipStore(directory: dir).add(items, asPill: true, now: t0)
    let reopened = ClipStore(directory: dir, now: t0)
    #expect(reopened.pill == held)
    #expect(reopened.types(for: held!.id) == items)
    #expect(reopened.history == [held!])
}

@Test func pastingTheItemOutEmptiesThePillButKeepsHistory() {
    let dir = tempDirectory()
    let store = ClipStore(directory: dir)
    let held = store.add(text("cut me"), asPill: true, now: t0)!
    store.clearPill()
    #expect(store.pill == nil)
    #expect(store.history == [held])
    #expect(ClipStore(directory: dir, now: t0).pill == nil)
    #expect(ClipStore(directory: dir, now: t0).types(for: held.id) != nil)
}

@Test func theSameCopyTwiceIsOneEntry() {
    let store = ClipStore(directory: tempDirectory())
    let first = store.add(text("same"), now: t0)
    let again = store.add(text("same"), asPill: true, now: t0.addingTimeInterval(1))
    #expect(again?.id == first?.id)
    #expect(store.history.count == 1)
    #expect(store.pill?.id == first?.id)
}

@Test func changesAreAnnounced() {
    let store = ClipStore(directory: tempDirectory())
    var changes = 0
    store.onChange = { changes += 1 }
    let held = store.add(text("a"), asPill: true, now: t0)
    store.clearPill()
    #expect(changes == 2)
    #expect(held != nil)
}

@Test func aMissingBlobDropsTheItemOnLoad() throws {
    let dir = tempDirectory()
    let item = ClipStore(directory: dir).add(text("gone"), now: t0)!
    try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(item.id)"))
    #expect(ClipStore(directory: dir, now: t0).history.isEmpty)
}
