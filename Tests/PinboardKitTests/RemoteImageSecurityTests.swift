import Foundation
import SafeImageDownload
import XCTest
@testable import PinboardKit

final class RemoteImageSecurityTests: XCTestCase {
    func testSocketPolicyRejectsLocalAndReservedAddresses() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254",
                        "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "::", "fd00::1", "fe80::1",
                        "::ffff:127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::", "2001:db8::1"] {
            XCTAssertEqual(pinboard_image_address_is_public(address), 0, address)
        }
        for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            XCTAssertEqual(pinboard_image_address_is_public(address), 1, address)
        }
    }

    func testProductionTransportRejectsLocalConnection() {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = pinboard_download_image("http://127.0.0.1:1/private", 1024, &bytes, &count)
        XCTAssertEqual(result, 7, "CURLE_COULDNT_CONNECT: socket policy rejects before connect")
        XCTAssertNil(bytes)
        XCTAssertEqual(count, 0)
    }

    func testCredentialsNeverReachTransport() {
        let loader = RemoteImageLoader { _, _ in
            XCTFail("URL credentials must be rejected before transport")
            return Data()
        }
        var called = false
        loader.fetch(URL(string: "https://user:password@example.com/p.png")!) {
            XCTAssertNil($0)
            called = true
        }
        XCTAssertTrue(called)
    }

    func testConcurrentRequestsForOneImageAreCoalesced() {
        let lock = NSLock()
        var count = 0
        let loader = RemoteImageLoader { _, _ in
            lock.lock()
            count += 1
            lock.unlock()
            return Data([1, 2, 3])
        }
        let done = expectation(description: "both callers")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            loader.fetch(URL(string: "https://example.com/image.png")!) {
                XCTAssertEqual($0, Data([1, 2, 3]))
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(count, 1)
    }
}
