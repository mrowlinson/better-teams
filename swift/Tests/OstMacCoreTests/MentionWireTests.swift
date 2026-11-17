// MentionWireTests.swift — COMPOSER-B: broadcast special resolve.
import XCTest

@testable import OstMacCore

@MainActor
final class MentionWireTests: XCTestCase {
    func testSpecialsChannelGated() {
        XCTAssertEqual(MentionWire.displays(channel: true), ["channel", "team", "Everyone"])
        XCTAssertEqual(MentionWire.displays(channel: false), ["Everyone"])
    }

    func testIsSpecialDisplay() {
        XCTAssertTrue(MentionWire.isSpecialDisplay("channel"))
        XCTAssertTrue(MentionWire.isSpecialDisplay("Everyone"))
        XCTAssertTrue(MentionWire.isSpecialDisplay("@team"))
        XCTAssertFalse(MentionWire.isSpecialDisplay("Tom Becker"))
        XCTAssertFalse(MentionWire.isSpecialDisplay(""))
    }

    func testResolveBasic() {
        let refs = MentionWire.resolve(in: "hey @channel look", channel: true)
        XCTAssertEqual(refs.map(\.kind), ["channel"])
        XCTAssertEqual(refs.first?.id, "0")
        XCTAssertEqual(refs.first?.display, "channel")
        XCTAssertEqual(refs.first?.token, "@channel")
    }

    func testResolveCaseInsensitiveDedupedInOrder() {
        let refs = MentionWire.resolve(in: "@Everyone ping @CHANNEL then @everyone @team", channel: true)
        XCTAssertEqual(refs.map(\.kind), ["everyone", "channel", "team"])
    }

    func testResolveBounds() {
        // Glued tokens never tag.
        for fixed in ["x@channel", "@channelx", "@channel_x", "mail@channel.com"] {
            XCTAssertTrue(MentionWire.resolve(in: fixed, channel: true).isEmpty, fixed)
        }
        // Punctuation bounds tag.
        XCTAssertEqual(MentionWire.resolve(in: "(@team!)", channel: true).map(\.kind), ["team"])
    }

    func testResolveChannelGating() {
        // Offered kinds only: a typed @channel in a 1:1 stays plain text.
        XCTAssertTrue(MentionWire.resolve(in: "hi @channel", channel: false).isEmpty)
        XCTAssertEqual(
            MentionWire.resolve(in: "hi @everyone", channel: false).map(\.kind), ["everyone"])
    }

    func testResolveEmpty() {
        XCTAssertTrue(MentionWire.resolve(in: "plain text", channel: true).isEmpty)
        XCTAssertTrue(MentionWire.resolve(in: "", channel: true).isEmpty)
    }
}
