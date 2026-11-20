import XCTest
@testable import ALifeClient

/// Which of the characters' lines are said out loud, when, and in which
/// voice, with an engine that only writes down what it was asked to say.
@MainActor
final class NarratorTests: XCTestCase {
    /// Says nothing: writes each line down, and finishes it when told to,
    /// or when stopped.
    private final class Notebook: SpeechEngine {
        var said: [(text: String, voice: Int)] = []
        var stops = 0
        private var saying: CheckedContinuation<Void, Never>?

        var isSaying: Bool { saying != nil }

        func say(_ text: String, voice: Int) async {
            said.append((text, voice))
            await withCheckedContinuation { saying = $0 }
        }

        func stop() {
            stops += 1
            finishLine()
        }

        func finishLine() {
            saying?.resume()
            saying = nil
        }
    }

    private func wait(
        for description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    private func agent(_ id: String, _ text: String) -> Message {
        Message(id: id, kind: .agent, speaker: "Gardener", text: text)
    }

    // MARK: Earshot

    func testYouHearACharacterAFewTilesAway() {
        XCTAssertTrue(Earshot.contains(listener: (x: 0, z: 0), speaker: (x: 0, z: 0)))
        XCTAssertTrue(Earshot.contains(listener: (x: 0, z: 0), speaker: (x: 2, z: 2))) // about 2.8 tiles
        XCTAssertTrue(Earshot.contains(listener: (x: 10, z: 10), speaker: (x: 10, z: 7)))
        XCTAssertFalse(Earshot.contains(listener: (x: 0, z: 0), speaker: (x: 3, z: 1)))
        XCTAssertFalse(Earshot.contains(listener: (x: -5, z: 4), speaker: (x: 5, z: 4)))
    }

    // MARK: What is said

    func testOnlyWhatTheCharacterSaysIsSpoken() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let messages = [
            Message(id: "1", kind: .user, speaker: "You", text: "How are the roses?"),
            Message(id: "2", kind: .error, speaker: "Gardener", text: "Claude Code stopped."),
            agent("3", "They're **blooming**. See [the bed](garden/roses.md)."),
        ]
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: messages)], inEarshot: ["gardener"])
        await wait(for: "the line") { notebook.isSaying }
        XCTAssertEqual(notebook.said.map(\.text), ["They're blooming. See the bed."])
    }

    func testALineSaidOutOfEarshotIsntSaidWhenYouWalkOver() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("1", "Far away.")], isWorking: true)], inEarshot: [])
        // Walking over afterwards doesn't say it there and then.
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("1", "Far away.")], isWorking: true)], inEarshot: ["gardener"])
        narrator.listen(
            to: [Narrator.Speaker(id: "gardener", messages: [agent("1", "Far away."), agent("2", "Close by.")], isWorking: true)],
            inEarshot: ["gardener"]
        )
        await wait(for: "the line") { notebook.isSaying }
        XCTAssertEqual(notebook.said.map(\.text), ["Close by."])
    }

    func testEachLineIsSaidOnceInItsCharactersVoiceOneAtATime() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses.")])
        let builder = Narrator.Speaker(id: "builder", messages: [agent("b1", "Bricks.")])
        narrator.listen(to: [gardener, builder], inEarshot: ["gardener", "builder"])
        narrator.listen(to: [gardener, builder], inEarshot: ["gardener", "builder"]) // nothing new
        await wait(for: "the first line") { notebook.isSaying }
        XCTAssertEqual(notebook.said.map(\.text), ["Roses."]) // the Builder waits its turn

        notebook.finishLine()
        await wait(for: "the second line") { notebook.said.count == 2 && notebook.isSaying }
        notebook.finishLine()
        await wait(for: "quiet") { narrator.speaking == nil }
        XCTAssertEqual(notebook.said.map(\.text), ["Roses.", "Bricks."])
        XCTAssertEqual(notebook.said.map(\.voice), [0, 1])
    }

    func testWalkingAwayCutsTheCharacterOff() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses."), agent("g2", "And tulips.")])
        let builder = Narrator.Speaker(id: "builder", messages: [agent("b1", "Bricks.")])
        narrator.listen(to: [gardener, builder], inEarshot: ["gardener", "builder"])
        await wait(for: "the first line") { notebook.isSaying }

        // Still beside the Builder, but not the Gardener any more.
        narrator.listenerMoved(inEarshot: ["builder"])
        XCTAssertEqual(notebook.stops, 1)
        await wait(for: "the Builder") { notebook.said.count == 2 && notebook.isSaying }
        XCTAssertEqual(notebook.said.map(\.text), ["Roses.", "Bricks."])

        // Staying near the one talking doesn't stop it.
        narrator.listenerMoved(inEarshot: ["builder"])
        XCTAssertEqual(notebook.stops, 1)
        notebook.finishLine()
        await wait(for: "quiet") { narrator.speaking == nil }
        XCTAssertTrue(narrator.waiting.isEmpty)
    }

    // MARK: Calls

    func testLinesYouMissedTurnIntoACallWhenTheJobEnds() {
        let narrator = Narrator(engine: Notebook())
        let said = [agent("1", "Planting."), agent("2", "**Done**.")]
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: Array(said.prefix(1)), isWorking: true)], inEarshot: [])
        XCTAssertTrue(narrator.calls.isEmpty) // still on the job
        XCTAssertTrue(narrator.hasSomethingToSay("gardener"))

        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: said, isWorking: false)], inEarshot: [])
        XCTAssertEqual(narrator.calls.map(\.speakerID), ["gardener"])
        XCTAssertEqual(narrator.calls.first?.lines, ["Planting.", "Done."])
        XCTAssertTrue(narrator.isCalling("gardener"))
        XCTAssertTrue(narrator.hasSomethingToSay("gardener"))
    }

    func testLinesYouWalkAwayFromAreKeptForTheCall() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses."), agent("g2", "And tulips.")], isWorking: true)
        narrator.listen(to: [gardener], inEarshot: ["gardener"])
        await wait(for: "the first line") { notebook.isSaying }

        narrator.listenerMoved(inEarshot: [])
        let done = Narrator.Speaker(id: "gardener", messages: gardener.messages, isWorking: false)
        narrator.listen(to: [done], inEarshot: [])
        XCTAssertEqual(narrator.calls.first?.lines, ["Roses.", "And tulips."])
    }

    func testNoCallForLinesYouHeard() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let working = Narrator.Speaker(id: "gardener", messages: [agent("1", "Roses.")], isWorking: true)
        narrator.listen(to: [working], inEarshot: ["gardener"])
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: working.messages)], inEarshot: ["gardener"])
        await wait(for: "the line") { notebook.isSaying }
        XCTAssertTrue(narrator.calls.isEmpty)
        XCTAssertTrue(narrator.hasSomethingToSay("gardener")) // still saying it

        notebook.finishLine()
        await wait(for: "quiet") { narrator.speaking == nil }
        XCTAssertTrue(narrator.calls.isEmpty)
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
    }

    func testWhatWasSaidBeforeYouCameIsLetGo() {
        let narrator = Narrator(engine: Notebook())
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("1", "Long ago.")])
        narrator.letGo(of: [gardener])
        narrator.listen(to: [gardener], inEarshot: [])
        XCTAssertTrue(narrator.calls.isEmpty)
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
    }

    func testTakingACallSaysWhatYouMissedWhereverYouAre() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        let builder = Narrator.Speaker(id: "builder", messages: [agent("b1", "Bricks.")])
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses."), agent("g2", "Tulips.")])
        narrator.listen(to: [builder, gardener], inEarshot: [])

        narrator.take(callFrom: "gardener")
        XCTAssertEqual(narrator.calls.map(\.speakerID), ["builder"])
        await wait(for: "the first line") { notebook.isSaying }
        narrator.listenerMoved(inEarshot: []) // far away, and it carries on
        XCTAssertEqual(notebook.stops, 0)
        XCTAssertTrue(narrator.hasSomethingToSay("gardener"))

        notebook.finishLine()
        await wait(for: "the second line") { notebook.said.count == 2 && notebook.isSaying }
        notebook.finishLine()
        await wait(for: "quiet") { narrator.speaking == nil }
        XCTAssertEqual(notebook.said.map(\.text), ["Roses.", "Tulips."])
        XCTAssertEqual(notebook.said.map(\.voice), [1, 1])
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
        XCTAssertTrue(narrator.hasSomethingToSay("builder")) // still ringing
    }

    func testHangingUpLetsTheCallGoUnsaid() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("1", "Roses.")])], inEarshot: [])
        narrator.hangUp(on: "gardener")
        XCTAssertTrue(narrator.calls.isEmpty)
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
        await Task.yield()
        XCTAssertTrue(notebook.said.isEmpty)

        // Lines kept while it's still at work go too.
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("2", "Tulips.")], isWorking: true)], inEarshot: [])
        narrator.hangUp(on: "gardener")
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("2", "Tulips.")])], inEarshot: [])
        XCTAssertTrue(narrator.calls.isEmpty)
    }

    func testHangingUpStopsACallYouTook() async {
        let notebook = Notebook()
        let narrator = Narrator(engine: notebook)
        narrator.listen(to: [Narrator.Speaker(id: "gardener", messages: [agent("1", "Roses."), agent("2", "Tulips.")])], inEarshot: [])
        narrator.take(callFrom: "gardener")
        await wait(for: "the first line") { notebook.isSaying }
        narrator.hangUp(on: "gardener")
        XCTAssertEqual(notebook.stops, 1)
        await wait(for: "quiet") { narrator.speaking == nil }
        XCTAssertEqual(notebook.said.map(\.text), ["Roses."])
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
    }

    func testSeveralCallsQueueOneForEachCharacter() {
        let narrator = Narrator(engine: Notebook())
        let builder = Narrator.Speaker(id: "builder", messages: [agent("b1", "Bricks.")], isWorking: true)
        let gardener = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses.")])
        narrator.listen(to: [builder, gardener], inEarshot: [])
        XCTAssertEqual(narrator.calls.map(\.speakerID), ["gardener"])

        let builderDone = Narrator.Speaker(id: "builder", messages: builder.messages)
        narrator.listen(to: [builderDone, gardener], inEarshot: [])
        XCTAssertEqual(narrator.calls.map(\.speakerID), ["gardener", "builder"])

        // Another job done before you answered adds to the same call.
        let gardenerAgain = Narrator.Speaker(id: "gardener", messages: [agent("g1", "Roses."), agent("g2", "Tulips.")])
        narrator.listen(to: [builderDone, gardenerAgain], inEarshot: [])
        XCTAssertEqual(narrator.calls.map(\.speakerID), ["gardener", "builder"])
        XCTAssertEqual(narrator.calls.first?.lines, ["Roses.", "Tulips."])
    }

    // MARK: How it sounds

    func testMarkdownIsReadAsProse() {
        let markdown = """
        ## Done

        I built a **café** next to the house:

        - It's 4 by 3 tiles.
        - Its file is `buildings/cafe.md`.

        ```yaml
        kind: cafe
        x: 20
        ```

        | Kind | Where |
        |------|-------|
        | cafe | 20, 30 |

        More on a*life at https://example.com/a-life, or see [the README](README.md)
        """
        XCTAssertEqual(
            SpokenText.from(markdown),
            "Done. I built a café next to the house: It's 4 by 3 tiles. Its file is buildings/cafe.md. Kind, Where. cafe, 20, 30. More on a life at, or see the README"
        )
    }

    func testAMessageThatIsAllCodeSaysNothing() {
        XCTAssertEqual(SpokenText.from("```swift\nlet x = 1\n```"), "")
    }
}
