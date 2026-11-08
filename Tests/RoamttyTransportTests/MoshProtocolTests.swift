import XCTest
@testable import RoamttyTransport

final class MoshProtocolTests: XCTestCase {
    private let key = "4NeCCgvZFe2RnPgrcU1PQw"

    func testParsesMoshConnectAndRejectsInvalidPortsAndKeys() {
        XCTAssertEqual(Mosh.parseConnect("\r\nMOSH CONNECT 60001 \(key)\r\nmosh-server"),
                       Mosh.Connect(port: 60001, key: key))
        XCTAssertNil(Mosh.parseConnect("MOSH CONNECT 70000 \(key)"))
        XCTAssertNil(Mosh.parseConnect("MOSH CONNECT 0 \(key)"))
        XCTAssertNil(Mosh.parseConnect("MOSH CONNECT 60001 not-a-key"))
        // What `startMosh` takes: one line of exactly four fields, on a port mosh-server picks by itself.
        XCTAssertNil(Mosh.parseConnect("MOSH CONNECT 59999 \(key)"))
        XCTAssertNil(Mosh.parseConnect("MOSH CONNECT 60001 \(key) extra"))
        XCTAssertNil(Mosh.parseConnect("xMOSH CONNECT 60001 \(key)"))
        XCTAssertEqual(Mosh.parseConnect("MOSH CONNECT 61000 \(key)"), Mosh.Connect(port: 61000, key: key))
    }

    func testInstructionMatchesAndroidProtobufIncludingUnsignedShutdown() throws {
        let instruction = Mosh.Instruction(oldNum: 3, newNum: .max, ackNum: 7, throwawayNum: 3, diff: Data("hi".utf8))
        let expected = hex("0802100318ffffffffffffffffff012007280332026869")
        XCTAssertEqual(instruction.encode(), expected)
        XCTAssertEqual(try Mosh.Instruction.decode(expected), instruction)
    }

    func testUserAndHostMessagesMatchAndroidFieldNumbers() throws {
        let keys = Mosh.UserEvent.keys(Data("hi".utf8)).encode()
        let resize = Mosh.UserEvent.resize(columns: 80, rows: 24).encode()
        XCTAssertEqual(keys, hex("120422026869"))
        XCTAssertEqual(resize, hex("1a0428503018"))
        XCTAssertEqual(Mosh.userMessage([keys, resize]), hex("0a061204220268690a061a0428503018"))
        XCTAssertEqual(try Mosh.hostMessage(hex("0a061204220268690a061a04285030180a043a024005")),
                       [.bytes(Data("hi".utf8)), .resize(columns: 80, rows: 24)])
    }

    func testCryptoMatchesAndroidBouncyCastleVectorsAndAdvancesNonce() throws {
        // Generated using MoshProtocol.kt's exact OCB setup, BouncyCastle 1.80.
        let crypto = try Mosh.Crypto(key: key)
        XCTAssertEqual(try crypto.seal(Data("hello".utf8)),
                       hex("000000000000000071780710f626b72bf4346521f23956cd7b856fd516"))
        XCTAssertEqual(try crypto.seal(Data("hello".utf8)),
                       hex("0000000000000001cd02a6fadb4930becfca445bf0851b80e054526e13"))
        XCTAssertEqual(crypto.open(hex("8000000000000000ebc3e6eb0f22d8a1d184da7264c0d1fab3b18ba133")), Data("hello".utf8))
        XCTAssertEqual(crypto.open(hex("8000000000000001c85295b83f4ed8d0db5066229546e0a6bddc01d383")), Data("hello".utf8))
    }

    func testCryptoRejectsReflectedTamperedAndTruncatedDatagrams() throws {
        let crypto = try Mosh.Crypto(key: key)
        var reflected = try crypto.seal(Data("hello".utf8))
        XCTAssertNil(crypto.open(reflected))
        reflected[0] |= 0x80
        XCTAssertNil(crypto.open(reflected))
        var server = hex("8000000000000000ebc3e6eb0f22d8a1d184da7264c0d1fab3b18ba133")
        server[server.count - 1] ^= 1
        XCTAssertNil(crypto.open(server))
        XCTAssertNil(crypto.open(Data(repeating: 0, count: 23)))
        XCTAssertThrowsError(try Mosh.Crypto(key: "bad"))
    }

    func testFragmentHeaderAndOutOfOrderReassembly() throws {
        let fragments = try Mosh.fragments(id: 9, payload: Data("abcdefgh".utf8), maxPayload: 3)
        XCTAssertEqual(fragments, [hex("00000000000000090000616263"), hex("00000000000000090001646566"), hex("000000000000000980026768")])
        var assembly = Mosh.Assembly()
        XCTAssertNil(assembly.add(fragments[2]))
        XCTAssertNil(assembly.add(fragments[0]))
        XCTAssertNil(assembly.add(fragments[0]))
        XCTAssertEqual(assembly.add(fragments[1]), Data("abcdefgh".utf8))
        XCTAssertNil(assembly.add(fragments[2]))
    }

    func testNewerInstructionDiscardsPartialOlderInstruction() throws {
        let old = try Mosh.fragments(id: 1, payload: Data("old".utf8), maxPayload: 2)
        let new = try Mosh.fragments(id: 2, payload: Data("new".utf8), maxPayload: 2)
        var assembly = Mosh.Assembly()
        XCTAssertNil(assembly.add(old[0]))
        XCTAssertNil(assembly.add(new[0]))
        XCTAssertNil(assembly.add(old[1]))
        XCTAssertEqual(assembly.add(new[1]), Data("new".utf8))
    }

    func testCompressionPreservesBinaryDataAndRejectsBombsAndTruncation() throws {
        let input = Data((0..<30_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let compressed = try Mosh.compress(input)
        XCTAssertEqual(try Mosh.decompress(compressed), input)
        XCTAssertThrowsError(try Mosh.decompress(compressed, limit: 100))
        XCTAssertThrowsError(try Mosh.decompress(Data(compressed.dropLast())))
        XCTAssertThrowsError(try Mosh.decompress(Data()))
    }

    func testMalformedProtobufDoesNotOverflowOrReadOutsideInput() {
        for malformed in ["00", "0880808080808080808002", "32056869", "09", "0f", "32ffffffffffffffffff01"] {
            XCTAssertThrowsError(try Mosh.Instruction.decode(hex(malformed)), malformed)
        }
    }

    func testUnknownFixedFieldsAreSkippedWithoutLosingInstruction() throws {
        let data = hex("080239000000000000000045000000001005180620072805")
        XCTAssertEqual(try Mosh.Instruction.decode(data), Mosh.Instruction(oldNum: 5, newNum: 6, ackNum: 7, throwawayNum: 5))
    }

    private func hex(_ source: String) -> Data {
        var bytes = [UInt8]()
        var index = source.startIndex
        while index < source.endIndex {
            let next = source.index(index, offsetBy: 2)
            bytes.append(UInt8(source[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}
