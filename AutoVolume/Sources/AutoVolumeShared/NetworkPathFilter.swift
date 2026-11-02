import Foundation

/// The parts of an `NWPath` that mean "the network the NAS is reached over changed", with everything
/// that merely flaps stripped out. `NWPathMonitor` is chatty: AWDL (AirDrop/Handoff), the low-latency
/// WLAN interface and Wi-Fi-hotspot interfaces come and go constantly without the real network
/// changing, and every update used to trigger a full volume check plus log lines — about 29,000 times
/// in a week on one affected machine.
///
/// Kept free of the `Network` framework so it can be unit tested (`NWPath` cannot be constructed).
public struct NetworkPathSignature: Equatable {
    public struct Interface: Equatable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public let status: String
    /// Sorted, with peer-to-peer interfaces removed.
    public let interfaces: [Interface]
    /// Sorted gateway descriptions. Joining a different Wi-Fi network or subnet keeps the same
    /// interface (`en0`) and only changes the gateway, so it has to be part of the signature.
    public let gateways: [String]

    public init(status: String, interfaces: [Interface], gateways: [String] = []) {
        self.status = status
        self.interfaces = interfaces
            .filter { !Self.isPeerToPeer(interfaceName: $0.name) }
            .sorted { ($0.name, $0.type) < ($1.name, $1.type) }
        self.gateways = gateways.sorted()
    }

    /// `awdl0`, `llw0`, `ap1`, `anpi0`: Apple peer-to-peer / hotspot interfaces. VPN tunnels (`utun*`)
    /// are deliberately *not* here — a VPN coming up is exactly what makes a remote NAS reachable.
    static func isPeerToPeer(interfaceName name: String) -> Bool {
        name.range(of: "^(awdl|llw|ap|anpi)[0-9]*$", options: .regularExpression) != nil
    }
}

/// Remembers the last path signature and says whether a new one is worth a check.
public struct NetworkPathChangeFilter {
    private var last: NetworkPathSignature?

    public init() {}

    /// `true` for the first update (the agent should check once at startup) and whenever the
    /// signature differs from the previous one.
    public mutating func shouldTrigger(for signature: NetworkPathSignature) -> Bool {
        defer { last = signature }
        return last != signature
    }
}
