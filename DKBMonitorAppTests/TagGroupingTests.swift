import Foundation
import Testing
@testable import DKB_Monitor

@Suite struct TagGroupingTests {
    private struct Row {
        let name: String
        let tag: String?
    }

    private func names(_ result: [(group: String, items: [Row])]) -> [String] {
        result.map(\.group)
    }

    @Test func untaggedRowsBecomeTheUngroupedSection() {
        let result = TagGrouping.groups([Row(name: "a", tag: nil)]) { $0.tag }
        #expect(names(result) == [TagGrouping.ungroupedLabel])
        #expect(result[0].items.map(\.name) == ["a"])
    }

    @Test func sectionsAreAlphabeticalWithUngroupedLast() {
        let rows = [
            Row(name: "a", tag: "Prod"),
            Row(name: "b", tag: nil),
            Row(name: "c", tag: "Dev"),
        ]
        #expect(names(TagGrouping.groups(rows) { $0.tag }) == ["Dev", "Prod", TagGrouping.ungroupedLabel])
    }

    @Test func preferredOrderComesFirstAndTheRestStayAlphabetical() {
        let rows = [
            Row(name: "a", tag: "Alpha"),
            Row(name: "b", tag: "Zeta"),
            Row(name: "c", tag: "Mid"),
        ]
        let result = TagGrouping.groups(rows, preferredOrder: ["Zeta"]) { $0.tag }
        #expect(names(result) == ["Zeta", "Alpha", "Mid"])
    }

    /// The saved order can name a group whose every row has since moved
    /// away or been deleted; it must not produce an empty section.
    @Test func preferredOrderIgnoresGroupsNoRowUses() {
        let rows = [Row(name: "a", tag: "Prod")]
        #expect(names(TagGrouping.groups(rows, preferredOrder: ["Gone", "Prod"]) { $0.tag }) == ["Prod"])
    }

    /// Untagged rows are not a group the user arranged, so no saved order
    /// can lift them above one that was.
    @Test func ungroupedStaysLastEvenIfTheSavedOrderNamesItFirst() {
        let rows = [Row(name: "a", tag: nil), Row(name: "b", tag: "Prod")]
        let result = TagGrouping.groups(rows, preferredOrder: [TagGrouping.ungroupedLabel]) { $0.tag }
        #expect(names(result) == ["Prod", TagGrouping.ungroupedLabel])
    }

    /// A group a user literally names "Ungrouped" used to be placed twice:
    /// once by the saved order and again by the untagged rule, giving two
    /// sections with the same heading.
    @Test func aGroupNamedUngroupedMergesIntoTheUntaggedSectionOnce() {
        let rows = [
            Row(name: "a", tag: TagGrouping.ungroupedLabel),
            Row(name: "b", tag: nil),
        ]
        let result = TagGrouping.groups(rows, preferredOrder: [TagGrouping.ungroupedLabel]) { $0.tag }
        #expect(names(result) == [TagGrouping.ungroupedLabel])
        #expect(result[0].items.count == 2)
    }

    @Test func rowOrderWithinASectionIsPreserved() {
        let rows = [
            Row(name: "first", tag: "Prod"),
            Row(name: "other", tag: "Dev"),
            Row(name: "second", tag: "Prod"),
        ]
        let result = TagGrouping.groups(rows) { $0.tag }
        #expect(result.first { $0.group == "Prod" }?.items.map(\.name) == ["first", "second"])
    }

    @Test func noRowsMeansNoSections() {
        #expect(TagGrouping.groups([Row]()) { $0.tag }.isEmpty)
    }
}
