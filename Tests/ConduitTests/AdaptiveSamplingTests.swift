import Testing
import Foundation
@testable import Conduit

/// The sampler cannot be observed by timing it, so these drive the state that
/// decides the rate instead.
@Suite("Adaptive sampling")
struct AdaptiveSamplingTests {

    @Test("a fresh sampler runs at the fast rate rather than easing in")
    func startsFast() async {
        let sampler = ThroughputSampler()
        #expect(await sampler.currentInterval == ThroughputSampler.activeInterval)
    }

    @Test("turning adaptation off pins the fast rate")
    func canBeDisabled() async {
        let sampler = ThroughputSampler()
        await sampler.setAdaptive(false)
        #expect(await sampler.currentInterval == ThroughputSampler.activeInterval)
    }

    /// A drive appearing is exactly the moment the meter needs to be
    /// responsive, so hot-plug resets the quiet counter.
    @Test("a topology change wakes the sampler back to the fast rate")
    func hotPlugWakesUp() async {
        let sampler = ThroughputSampler()
        await sampler.invalidateTopology()
        #expect(await sampler.currentInterval == ThroughputSampler.activeInterval)
    }

    @Test("the idle rate is genuinely slower, and both are sane")
    func rates() {
        #expect(ThroughputSampler.idleInterval > ThroughputSampler.activeInterval)
        #expect(ThroughputSampler.activeInterval == .milliseconds(250))
        #expect(ThroughputSampler.idleInterval == .milliseconds(1000))
    }
}

@Suite("Connection diagnosis")
struct ConnectionDiagnosisTests {

    private func identity(link: USBLink?) -> DeviceIdentity {
        DeviceIdentity(id: 1, bsdName: "disk4", productName: "SanDisk 3.2Gen1",
                       vendorName: "SanDisk", serialNumber: "SN1", interconnect: .usb,
                       location: "External", capacityBytes: 123_009_761_280,
                       isRemovable: true, isEjectable: true, isSolidState: true,
                       usbLink: link, childBSDNames: [], volumes: [])
    }

    /// The notification only earns its interruption when something is wrong.
    /// A drive that connected perfectly must produce silence.
    @MainActor
    @Test("a healthy connection says nothing at all")
    func healthyIsSilent() {
        let good = USBLink.make(bitsPerSecond: 10_000_000_000, hubs: [], uasp: true)
        #expect(Notifier.connectionDiagnosis(for: identity(link: good)) == nil)
    }

    @MainActor
    @Test("a USB 2.0 fallback is called out")
    func usb2IsFlagged() {
        let slow = USBLink.make(bitsPerSecond: 480_000_000, hubs: [], uasp: false)
        let message = Notifier.connectionDiagnosis(for: identity(link: slow))
        #expect(message?.contains("USB 2.0") == true)
    }

    @MainActor
    @Test("a hub-capped link is called out ahead of everything else")
    func hubCapWins() {
        let capped = USBLink.make(bitsPerSecond: 480_000_000, hubs: ["Dock"],
                                  uasp: true, cappedByHub: true)
        let message = Notifier.connectionDiagnosis(for: identity(link: capped))
        #expect(message?.contains("hub") == true)
    }

    @MainActor
    @Test("bulk-only transport on a fast link is called out")
    func botIsFlagged() {
        let bot = USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: false)
        #expect(Notifier.connectionDiagnosis(for: identity(link: bot))?.contains("bulk-only") == true)
    }

    @MainActor
    @Test("a non-USB drive has nothing USB-specific to report")
    func nonUSBIsSilent() {
        #expect(Notifier.connectionDiagnosis(for: identity(link: nil)) == nil)
    }
}
