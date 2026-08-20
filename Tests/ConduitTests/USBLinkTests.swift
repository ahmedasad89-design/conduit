import Testing
@testable import Conduit

/// The values in these tests are not invented — they were read off real
/// hardware on the machine this was built on. `UsbLinkSpeed`, `USBSpeed` and
/// `Device Speed` all describe the same link and all disagree about how, so
/// this is the single easiest place in the app to be confidently wrong.
@Suite("USB link speed resolution")
struct USBLinkTests {

    // Ground truth, read from IORegistry:
    //   USB 2.0 hub      UsbLinkSpeed 480000000    USBSpeed 3  Device Speed 2
    //   USB 3.2 hub      UsbLinkSpeed 10000000000  USBSpeed 5  Device Speed 4
    //   5 Gb/s LAN       UsbLinkSpeed 5000000000   USBSpeed 4  Device Speed 3
    //   SanDisk 3.2Gen1  UsbLinkSpeed 5000000000   USBSpeed 4  Device Speed 3

    @Test("UsbLinkSpeed wins when present, because it needs no enum table at all")
    func prefersLinkSpeed() {
        // Deliberately contradictory: if the enums were consulted first this
        // would come back as something other than 10 Gb/s.
        #expect(USBLink.bitsPerSecond(linkSpeed: 10_000_000_000, usbSpeed: 3, deviceSpeed: 2)
                == 10_000_000_000)
    }

    @Test("USBSpeed uses tIOUSBHostConnectionSpeed, where High is 3 and Low is 2")
    func usbSpeedEnum() {
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 1, deviceSpeed: nil) == 12_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 2, deviceSpeed: nil) == 1_500_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 3, deviceSpeed: nil) == 480_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 4, deviceSpeed: nil) == 5_000_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 5, deviceSpeed: nil) == 10_000_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 6, deviceSpeed: nil) == 20_000_000_000)
    }

    @Test("Device Speed uses the legacy enum, where High is 2 — one lower throughout")
    func deviceSpeedEnum() {
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 0) == 1_500_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 1) == 12_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 2) == 480_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 3) == 5_000_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 4) == 10_000_000_000)
    }

    /// The regression that matters: reading `Device Speed` with the `USBSpeed`
    /// table turns a 480 Mb/s USB 2.0 device into a 1.5 Mb/s one, and a 5 Gb/s
    /// drive into a 480 Mb/s one. Both are silently plausible.
    @Test("the two enums genuinely disagree for the same real device")
    func enumsAreNotInterchangeable() {
        let viaUSBSpeed = USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 2, deviceSpeed: nil)
        let viaDeviceSpeed = USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: 2)
        #expect(viaUSBSpeed != viaDeviceSpeed)
        #expect(viaUSBSpeed == 1_500_000)
        #expect(viaDeviceSpeed == 480_000_000)
    }

    @Test("falls through the tiers and gives up rather than guessing")
    func fallsThroughTiers() {
        #expect(USBLink.bitsPerSecond(linkSpeed: 0, usbSpeed: 3, deviceSpeed: nil) == 480_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 99, deviceSpeed: 3) == 5_000_000_000)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: nil, deviceSpeed: nil) == nil)
        #expect(USBLink.bitsPerSecond(linkSpeed: nil, usbSpeed: 99, deviceSpeed: 99) == nil)
    }

    @Test("generation labels and ceilings match the measured hardware")
    func ceilings() {
        let gen1 = USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: true)
        #expect(gen1.generation == "USB 3.2 Gen 1 (5 Gb/s)")
        #expect(gen1.lineRateLabel == "5 Gb/s")
        // 8b/10b encoding: 5000 Mb/s of signalling carries 500 MB/s of data.
        #expect(gen1.encodedCeilingMBps == 500)
        // The SanDisk measured 378.6 MB/s read against this ceiling — 86%.
        #expect(gen1.practicalCeilingMBps == 440)

        let usb2 = USBLink.make(bitsPerSecond: 480_000_000, hubs: [], uasp: false)
        #expect(usb2.generation == "USB 2.0 High-Speed")
        #expect(usb2.encodedCeilingMBps == 60)
    }

    @Test("dropping from UASP to bulk-only roughly halves the expected ceiling")
    func uaspMatters() {
        let uasp = USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: true)
        let bot = USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: false)
        #expect(uasp.practicalCeilingMBps > bot.practicalCeilingMBps * 1.5)
    }

    @Test("hub state is carried through to the warnings the UI shows")
    func hubs() {
        let direct = USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: true)
        #expect(!direct.isBottleneckedByHub)
        #expect(!direct.cappedByHub)

        let behindHubs = USBLink.make(bitsPerSecond: 480_000_000,
                                      hubs: ["USB2.0 Hub", "USB2.1 Hub"],
                                      uasp: false, cappedByHub: true)
        #expect(behindHubs.isBottleneckedByHub)
        #expect(behindHubs.cappedByHub)
        #expect(behindHubs.hubsInPath.count == 2)
    }

    @Test("sub-gigabit rates are labelled in Mb/s, not a fractional Gb/s")
    func labels() {
        #expect(USBLink.make(bitsPerSecond: 480_000_000, hubs: [], uasp: false).lineRateLabel
                == "480 Mb/s")
        #expect(USBLink.make(bitsPerSecond: 10_000_000_000, hubs: [], uasp: true).lineRateLabel
                == "10 Gb/s")
    }
}
