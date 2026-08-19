import XCTest
@testable import ClaudeRCManager

final class SessionCounterTests: XCTestCase {
    private final class Box { var values: [Int] = [] }

    /// Collects reports; the counter calls back on the feeding thread, and
    /// every test here feeds synchronously from the test thread.
    private func makeSUT() -> (SessionCounter, () -> [Int]) {
        let box = Box()
        let counter = SessionCounter()
        counter.onChange = { box.values.append($0) }
        return (counter, { box.values })
    }

    private func feed(_ counter: SessionCounter, _ text: String) {
        counter.feed(Data(text.utf8))
    }

    func testLastCountInTextWins() {
        XCTAssertEqual(SessionCounter.lastCount(in: "Capacity: 0/32 … Capacity: 3/32"), 3)
    }

    func testNoCountReturnsNil() {
        XCTAssertNil(SessionCounter.lastCount(in: "Connecting · website · main"))
    }

    func testSpacingVariantIsMatched() {
        XCTAssertEqual(SessionCounter.lastCount(in: "Capacity:  7/32"), 7)
    }

    func testEscapeSequencesAroundTheCountAreIgnored() {
        let text = "\u{1B}[32mCapacity: 2\u{1B}[0m/32"
        let (counter, values) = makeSUT()
        feed(counter, text)
        XCTAssertEqual(values(), [2])
    }

    func testChangeIsReportedOnceUntilItChanges() {
        let (counter, values) = makeSUT()
        feed(counter, "Capacity: 1/32\n")
        feed(counter, "Capacity: 1/32\n")
        feed(counter, "Capacity: 2/32\n")
        XCTAssertEqual(values(), [1, 2])
    }

    func testMatchSplitAcrossTwoChunks() {
        let (counter, values) = makeSUT()
        feed(counter, "…Capa")
        feed(counter, "city: 4/32 · New sessions")
        XCTAssertEqual(values(), [4])
    }

    func testLongChunkWithoutAMatchDoesNotBreakTheNextOne() {
        let (counter, values) = makeSUT()
        feed(counter, String(repeating: "x", count: 10_000))
        feed(counter, "Capacity: 5/32")
        XCTAssertEqual(values(), [5])
    }

    /// Fails if the carry-over were unbounded: the "Capa" prefix is pushed
    /// out of the retained tail by the filler, so the split must not match.
    func testFragmentOlderThanTheCarryOverIsDropped() {
        let (counter, values) = makeSUT()
        feed(counter, "Capa")
        feed(counter, String(repeating: "x", count: SessionCounter.carryOver))
        feed(counter, "city: 8/32")
        XCTAssertEqual(values(), [])
    }
}
