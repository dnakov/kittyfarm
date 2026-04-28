import Foundation
import XCTest
@testable import KittyFarm

final class SimulatorPairingTests: XCTestCase {
    func testDeviceDescriptorIdentifiesWatchAndIPhoneSimulators() {
        let watch = DeviceDescriptor.iOSSimulator(
            udid: "WATCH-UDID",
            name: "Apple Watch Series 11 (46mm)",
            runtime: "watchOS 26.0"
        )
        let phone = DeviceDescriptor.iOSSimulator(
            udid: "PHONE-UDID",
            name: "iPhone 17 Pro",
            runtime: "iOS 26.0"
        )
        let ipad = DeviceDescriptor.iOSSimulator(
            udid: "IPAD-UDID",
            name: "iPad Pro 13-inch",
            runtime: "iOS 26.0"
        )

        XCTAssertTrue(watch.isWatchSimulator)
        XCTAssertFalse(watch.isIPhoneSimulator)
        XCTAssertFalse(watch.canRunIOSApps)
        XCTAssertEqual(watch.defaultAspectRatio, 1.0)

        XCTAssertFalse(phone.isWatchSimulator)
        XCTAssertTrue(phone.isIPhoneSimulator)
        XCTAssertTrue(phone.canRunIOSApps)

        XCTAssertFalse(ipad.isWatchSimulator)
        XCTAssertFalse(ipad.isIPhoneSimulator)
        XCTAssertTrue(ipad.canRunIOSApps)
    }

    func testSimctlPairJSONDecoding() throws {
        let pairs = try SimctlManager.decodeDevicePairs(from: Data(Self.pairListJSON.utf8))

        XCTAssertEqual(pairs.count, 1)
        let pair = try XCTUnwrap(pairs.first)
        XCTAssertEqual(pair.id, "PAIR-ID")
        XCTAssertEqual(pair.watch.name, "Apple Watch Series 11 (46mm)")
        XCTAssertEqual(pair.watch.udid, "WATCH-UDID")
        XCTAssertEqual(pair.watch.state, "Booted")
        XCTAssertEqual(pair.phone.name, "iPhone 17 Pro")
        XCTAssertEqual(pair.phone.udid, "PHONE-UDID")
        XCTAssertEqual(pair.phone.state, "Booted")
        XCTAssertEqual(pair.state, "(active, connected)")
    }

    func testPairInfoFindsCompanionForDescriptor() throws {
        let pair = try XCTUnwrap(try SimctlManager.decodeDevicePairs(from: Data(Self.pairListJSON.utf8)).first)
        let watch = DeviceDescriptor.iOSSimulator(
            udid: "WATCH-UDID",
            name: "Apple Watch Series 11 (46mm)",
            runtime: "watchOS 26.0"
        )
        let phone = DeviceDescriptor.iOSSimulator(
            udid: "PHONE-UDID",
            name: "iPhone 17 Pro",
            runtime: "iOS 26.0"
        )

        XCTAssertTrue(pair.includes(watch))
        XCTAssertTrue(pair.includes(phone))
        XCTAssertEqual(pair.companionName(for: watch), "iPhone 17 Pro")
        XCTAssertEqual(pair.companionName(for: phone), "Apple Watch Series 11 (46mm)")
    }

    private static let pairListJSON = """
    {
      "pairs" : {
        "PAIR-ID" : {
          "watch" : {
            "name" : "Apple Watch Series 11 (46mm)",
            "udid" : "WATCH-UDID",
            "state" : "Booted"
          },
          "phone" : {
            "name" : "iPhone 17 Pro",
            "udid" : "PHONE-UDID",
            "state" : "Booted"
          },
          "state" : "(active, connected)"
        }
      }
    }
    """
}
