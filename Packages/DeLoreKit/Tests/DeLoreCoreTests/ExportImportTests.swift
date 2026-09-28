@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

final class ExportImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeThread(_ folder: String, file: Int = 1, json: String, layout: String = "your_instagram_activity/messages/inbox") throws {
        let directory = root.appendingPathComponent("export/\(layout)/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("message_\(file).json"))
    }

    private func standardExport() throws {
        try writeThread("maya_111", json: """
        {"participants":[{"name":"Maya"},{"name":"Alex"}],"title":"Maya","messages":[
          {"sender_name":"Alex","timestamp_ms":1700000004000,"content":"SECRET-CONTENT-ONE"},
          {"sender_name":"Maya","timestamp_ms":1700000003000,"content":"hey"},
          {"sender_name":"Alex","timestamp_ms":1700000002000,"photos":[{"uri":"x.jpg"}]},
          {"sender_name":"Alex","timestamp_ms":1700000002000,"content":"same ms"},
          {"sender_name":"Alex","timestamp_ms":1700000001000,"share":{"link":"https://example.com"}},
          {"sender_name":"Alex","timestamp_ms":1700000000500,"call_duration":30},
          {"sender_name":"Alex","timestamp_ms":1700000000000,"audio_files":[{"uri":"a.mp4"}]}
        ]}
        """)
        try writeThread("group_222", json: """
        {"participants":[{"name":"Alex"},{"name":"Sam"},{"name":"Jo \\u00c3\\u00a9"}],"title":"the group \\u00f0\\u009f\\u0094\\u00a5","messages":[
          {"sender_name":"Sam","timestamp_ms":1700000100000,"content":"yo"},
          {"sender_name":"Alex","timestamp_ms":1700000090000,"content":"SECRET-CONTENT-TWO"}
        ]}
        """)
        try writeThread("group_222", file: 2, json: """
        {"participants":[{"name":"Alex"},{"name":"Sam"}],"messages":[
          {"sender_name":"Alex","timestamp_ms":1600000000000,"content":"older file"}
        ]}
        """)
    }

    private func importer() throws -> (ExportImporter, LocalLibraryStore) {
        let library = LocalLibraryStore(root: root.appendingPathComponent("library"))
        return (ExportImporter(archive: DirectoryExportArchive(root: root.appendingPathComponent("export")), library: library), library)
    }

    func testOwnerIsResolvedAsParticipantInEveryThread() async throws {
        try standardExport()
        let (importer, _) = try importer()
        let resolution = try await importer.resolveOwner()
        XCTAssertEqual(resolution, .resolved(name: "Alex"))
    }

    func testAmbiguousOwnerAsksTheUser() async throws {
        try writeThread("only_1", json: #"{"participants":[{"name":"A"},{"name":"B"}],"messages":[]}"#)
        let (importer, _) = try importer()
        let resolution = try await importer.resolveOwner()
        guard case let .needsChoice(candidates) = resolution else { return XCTFail("expected a choice") }
        XCTAssertEqual(Set(candidates), ["A", "B"])
    }

    func testImportKeepsOnlyOwnerMessagesWithoutContent() async throws {
        try standardExport()
        let (importer, library) = try importer()
        let overview = try await importer.importLibrary(ownerName: "Alex")

        let maya = try XCTUnwrap(overview.conversations.first { $0.id.rawValue == "maya_111" })
        XCTAssertEqual(maya.sentByOwner, 5, "call entries are excluded")
        XCTAssertEqual(maya.receivedFromOthers, 1)
        XCTAssertEqual(maya.sentByKind[.media], 1)
        XCTAssertEqual(maya.sentByKind[.link], 1)
        XCTAssertEqual(maya.sentByKind[.voice], 1)
        XCTAssertEqual(maya.sentByKind[.text], 2)

        let group = try XCTUnwrap(overview.conversations.first { $0.id.rawValue == "group_222" })
        XCTAssertEqual(group.sentByOwner, 2, "messages across multiple files")
        XCTAssertEqual(group.title, "the group 🔥", "mojibake repaired")

        // Messages from the library are oldest-first with unique ids, all owned by Alex.
        var messages: [DiscoveredMessage] = []
        for try await page in library.messagePages(in: maya.id, pageSize: 2) {
            XCTAssertLessThanOrEqual(page.count, 2)
            messages += page
        }
        XCTAssertEqual(messages.map(\.sentAt), messages.map(\.sentAt).sorted())
        XCTAssertEqual(Set(messages.map(\.ref)).count, messages.count)
        XCTAssertTrue(messages.allSatisfy { $0.authorID == InstagramExportFormat.participantID(forName: "Alex") })

        // No message content ever reaches disk.
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("library"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            XCTAssertFalse(text.contains("SECRET-CONTENT"), "content leaked into \(url.lastPathComponent)")
            XCTAssertFalse(text.contains("older file"))
        }
    }

    func testSameMillisecondMessagesGetDistinctStableIds() async throws {
        try writeThread("t_1", json: """
        {"participants":[{"name":"Me"},{"name":"You"}],"messages":[
          {"sender_name":"Me","timestamp_ms":5000,"content":"b"},
          {"sender_name":"Me","timestamp_ms":5000,"content":"a"}
        ]}
        """)
        try writeThread("t_2", json: #"{"participants":[{"name":"Me"},{"name":"Other"}],"messages":[]}"#)
        let (importer, library) = try importer()
        _ = try await importer.importLibrary(ownerName: "Me")
        var ids: [String] = []
        for try await page in library.messagePages(in: ConversationID("t_1"), pageSize: 10) { ids += page.map(\.ref.messageID) }
        XCTAssertEqual(ids, ["5000-0", "5000-1"])
    }

    func testConversationWithDuplicateOwnerNameIsNotCleanable() async throws {
        try writeThread("clash_1", json: """
        {"participants":[{"name":"Alex"},{"name":"Alex"}],"messages":[
          {"sender_name":"Alex","timestamp_ms":1,"content":"which alex?"}
        ]}
        """)
        try writeThread("normal_2", json: """
        {"participants":[{"name":"Alex"},{"name":"Kim"}],"messages":[
          {"sender_name":"Alex","timestamp_ms":2,"content":"hi"}
        ]}
        """)
        let (importer, library) = try importer()
        let overview = try await importer.importLibrary(ownerName: "Alex")
        let clash = try XCTUnwrap(overview.conversations.first { $0.id.rawValue == "clash_1" })
        XCTAssertTrue(clash.ownershipAmbiguous)
        XCTAssertFalse(clash.isCleanable)
        XCTAssertEqual(overview.sentByOwner, 1)

        let account = try await library.account()
        let store = InMemoryJobStore()
        let report = try await QueueBuilder(source: library, store: store)
            .build(request: .init(scope: .everything), account: account, conversations: overview.conversations, now: Date())
        XCTAssertEqual(report.job.itemCount, 1)
    }

    func testOwnerMissingFromParticipantsIsAmbiguous() async throws {
        try writeThread("left_1", json: """
        {"participants":[{"name":"Kim"}],"messages":[{"sender_name":"Alex","timestamp_ms":1,"content":"x"},{"sender_name":"Kim","timestamp_ms":2,"content":"y"}]}
        """)
        let (importer, _) = try importer()
        let overview = try await importer.importLibrary(ownerName: "Alex")
        XCTAssertTrue(overview.conversations[0].ownershipAmbiguous)
    }

    func testLegacyLayoutIsSupported() async throws {
        try writeThread("a_1", json: #"{"participants":[{"name":"Me"},{"name":"A"}],"messages":[{"sender_name":"Me","timestamp_ms":1,"content":"x"}]}"#, layout: "messages/inbox")
        try writeThread("b_2", json: #"{"participants":[{"name":"Me"},{"name":"B"}],"messages":[]}"#, layout: "messages/inbox")
        let (importer, _) = try importer()
        let resolution = try await importer.resolveOwner()
        XCTAssertEqual(resolution, .resolved(name: "Me"))
    }

    func testEmptyExportReportsNoMessages() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("export"), withIntermediateDirectories: true)
        let (importer, _) = try importer()
        let resolution = try await importer.resolveOwner()
        XCTAssertEqual(resolution, .noMessages)
    }

    func testOverviewExcludesCleanedMessages() async throws {
        try standardExport()
        let (importer, library) = try importer()
        let overview = try await importer.importLibrary(ownerName: "Alex")
        let maya = try XCTUnwrap(overview.conversations.first { $0.id.rawValue == "maya_111" })
        var firstTwo: [String] = []
        for try await page in library.messagePages(in: maya.id, pageSize: 2) {
            firstTwo = page.map(\.ref.key)
            break
        }
        let adjusted = try await library.overview(excluding: Set(firstTwo))
        let adjustedMaya = try XCTUnwrap(adjusted.conversations.first { $0.id == maya.id })
        XCTAssertEqual(adjustedMaya.sentByOwner, maya.sentByOwner - 2)
        XCTAssertEqual(adjusted.sentByOwner, overview.sentByOwner - 2)
    }

    func testReimportReplacesLibraryAtomically() async throws {
        try standardExport()
        let (importer, library) = try importer()
        _ = try await importer.importLibrary(ownerName: "Alex")
        let first = try library.overview().sentByOwner
        _ = try await importer.importLibrary(ownerName: "Alex")
        XCTAssertEqual(try library.overview().sentByOwner, first)
    }

    #if canImport(Compression)
    func testZipArchiveReadsStoredAndDeflatedEntries() throws {
        let zipURL = root.appendingPathComponent("export.zip")
        let payload = Data(#"{"participants":[{"name":"Me"}],"messages":[]}"#.utf8)
        try TestZipWriter.write(entries: [
            ("your_instagram_activity/messages/inbox/a_1/message_1.json", payload, false),
            ("your_instagram_activity/messages/inbox/b_2/message_1.json", payload, true)
        ], to: zipURL)
        let archive = try ZipExportArchive(url: zipURL)
        XCTAssertEqual(Set(try archive.entryPaths()).count, 2)
        for path in try archive.entryPaths() {
            XCTAssertEqual(try archive.contents(of: path), payload)
        }
    }
    #endif
}

#if canImport(Compression)
import Compression

/// Writes a tiny ZIP so the reader can be tested without fixtures.
enum TestZipWriter {
    static func write(entries: [(String, Data, Bool)], to url: URL) throws {
        var archive = Data()
        var central = Data()
        for (name, data, deflate) in entries {
            let offset = UInt32(archive.count)
            let body = deflate ? compress(data) : data
            let method: UInt16 = deflate ? 8 : 0
            let nameData = Data(name.utf8)
            var local = Data()
            local.append(le32(0x0403_4B50)); local.append(le16(20)); local.append(le16(0)); local.append(le16(method))
            local.append(le16(0)); local.append(le16(0)); local.append(le32(0))
            local.append(le32(UInt32(body.count))); local.append(le32(UInt32(data.count)))
            local.append(le16(UInt16(nameData.count))); local.append(le16(0))
            local.append(nameData)
            archive.append(local); archive.append(body)

            var header = Data()
            header.append(le32(0x0201_4B50)); header.append(le16(20)); header.append(le16(20)); header.append(le16(0))
            header.append(le16(method)); header.append(le16(0)); header.append(le16(0)); header.append(le32(0))
            header.append(le32(UInt32(body.count))); header.append(le32(UInt32(data.count)))
            header.append(le16(UInt16(nameData.count))); header.append(le16(0)); header.append(le16(0))
            header.append(le16(0)); header.append(le16(0)); header.append(le32(0)); header.append(le32(offset))
            header.append(nameData)
            central.append(header)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        var end = Data()
        end.append(le32(0x0605_4B50)); end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(entries.count))); end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(central.count))); end.append(le32(centralOffset)); end.append(le16(0))
        archive.append(end)
        try archive.write(to: url)
    }

    private static func compress(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let size = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(size)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
#endif
