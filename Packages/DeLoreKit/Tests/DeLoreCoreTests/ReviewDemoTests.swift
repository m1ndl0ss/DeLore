@testable import DeLoreCore
import Foundation
import XCTest

final class ReviewDemoTests: XCTestCase {
    func testSeedWritesLoadedOwnerChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = LocalLibraryStore(root: root)
        try ReviewDemo.seed(into: library)
        let overview = try library.overview()
        XCTAssertEqual(overview.conversations.count, 6)
        XCTAssertTrue(overview.conversations.allSatisfy(\.messagesLoaded))
        XCTAssertTrue(overview.conversations.allSatisfy(\.isCleanable))
        XCTAssertGreaterThan(overview.sentByOwner, 100)
    }

    func testDemoUnsendMarksGoneLocally() async throws {
        let unsender = ReviewDemoUnsendService()
        let target = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("demo-mom"), messageID: "demo-demo-mom-0"),
            authorID: ReviewDemo.account.ownerID,
            sentAt: Date(),
            kind: .text
        )
        let first = try await unsender.unsend(target)
        XCTAssertEqual(first, .unsent)
        let second = try await unsender.unsend(target)
        XCTAssertEqual(second, .alreadyGone)
        let presence = try await unsender.presence(of: target)
        XCTAssertEqual(presence, .gone)
    }
}
