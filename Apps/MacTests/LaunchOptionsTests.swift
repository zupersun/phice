import Foundation
import PhiceCore
import Testing
@testable import Phice

@Test func fakePosterTakesAnOptionalLogPath() {
    #expect(!LaunchOptions(arguments: ["Phice"]).fakePoster)

    let plain = LaunchOptions(arguments: ["Phice", "--fake-poster"])
    #expect(plain.fakePoster)
    #expect(plain.fakePosterLog == nil)

    let logged = LaunchOptions(
        arguments: ["Phice", "--fake-poster", "/tmp/calls.jsonl", "--auto-allow"])
    #expect(logged.fakePosterLog?.path == "/tmp/calls.jsonl")
    #expect(logged.autoAllow)

    // The next flag is not a path.
    let flagged = LaunchOptions(arguments: ["Phice", "--fake-poster", "--auto-allow"])
    #expect(flagged.fakePoster && flagged.fakePosterLog == nil && flagged.autoAllow)
}

@Test func nothingIsAutoAllowedByDefault() {
    #expect(!LaunchOptions(arguments: ["Phice"]).autoAllow)
}

@Test func theLogRecordsEveryCallAsOneDeterministicLine() throws {
    let url = tempDirectory().appendingPathComponent("calls.jsonl")
    let poster = LoggingPoster(log: url)
    poster.move(dx: 1.5, dy: -2, dragging: nil)
    poster.moveTo(x: 10, y: 20, dragging: .left)
    poster.button(.left, down: true, clicks: 2)
    poster.scroll(dx: 0, dy: 3.25, phase: .changed, momentum: nil)
    poster.scroll(dx: 0, dy: 0, phase: nil, momentum: .end)
    poster.shortcut(.missionControl)
    poster.forceClick()
    #expect(poster.perform(.copy))
    #expect(poster.perform(.shortcut(name: "Resize")))
    poster.paste(itemID: "abc")

    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines == [
        #"{"call":"move","dx":1.5,"dy":-2}"#,
        #"{"call":"moveTo","dragging":"left","x":10,"y":20}"#,
        #"{"button":"left","call":"button","clicks":2,"down":true}"#,
        #"{"call":"scroll","dx":0,"dy":3.25,"phase":"changed"}"#,
        #"{"call":"scroll","dx":0,"dy":0,"momentum":"end"}"#,
        #"{"call":"shortcut","shortcut":"missionControl"}"#,
        #"{"call":"forceClick"}"#,
        #"{"action":"copy","call":"perform"}"#,
        #"{"action":"shortcut","call":"perform","name":"Resize"}"#,
        #"{"call":"paste","itemID":"abc"}"#,
    ])
}

@Test func theLoggedLinesRoundTripThroughTheMirror() throws {
    let call = FakePoster.Call.scroll(dx: -0.1, dy: 7.0 / 3, phase: .began, momentum: nil)
    let line = try PosterCall(call).line()
    #expect(try JSONDecoder().decode(PosterCall.self, from: line) == PosterCall(call))
}

@Test func theLogKeepsTheCursorAndAppendsAcrossLaunches() throws {
    let url = tempDirectory().appendingPathComponent("calls.jsonl")
    let first = LoggingPoster(log: url)
    first.moveTo(x: 5, y: 6, dragging: nil)
    first.move(dx: 1, dy: 1, dragging: nil)
    #expect(first.cursor == (6, 7))
    LoggingPoster(log: url).forceClick()
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)
}

@Test func anUnwritableLogDoesNotStopThePoster() {
    let poster = LoggingPoster(log: tempDirectory())   // a directory, not a file
    poster.move(dx: 2, dy: 3, dragging: nil)
    #expect(poster.cursor == (2, 3))
}
