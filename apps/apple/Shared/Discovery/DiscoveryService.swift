import Foundation
import Network
import Combine

public final class DiscoveryService: @unchecked Sendable {
    public static let shared = DiscoveryService()

    private let queue = DispatchQueue(label: "com.nearside.discovery", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var localIdentity: String = ""
    private var localDeviceName: String = ""
    private var isReceivingActive: Bool = true
    private var boundPort: UInt16 = 41433

    public var onDiscoveredDevicesChanged: (([NearsideDevice]) -> Void)?

    private var discoveredMap: [String: NearsideDevice] = [:]

    public init() {}

    public func startAdvertising(
        identity: String,
        deviceName: String,
        port: UInt16 = 41433,
        isReceiving: Bool = true
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.localIdentity = identity
            self.localDeviceName = deviceName
            self.isReceivingActive = isReceiving
            self.boundPort = port
            self.setupListener()
        }
    }

    public func updateReceivingStatus(_ isReceiving: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isReceivingActive = isReceiving
            self.updateTxtRecord()
        }
    }

    private func setupListener() {
        listener?.cancel()

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: boundPort) ?? .any)
            self.listener = newListener

            let sanitizedName = localDeviceName.replacingOccurrences(of: "'", with: "")
            let serviceName = "Nearside-\(sanitizedName)"

            var txt = NWTXTRecord()
            txt["v"] = "1"
            txt["id"] = localIdentity
            txt["name"] = localDeviceName
            txt["os"] = "macos"
            txt["pair"] = "1"
            txt["recv"] = isReceivingActive ? "1" : "0"

            newListener.service = NWListener.Service(
                name: serviceName,
                type: "_nearside._tcp",
                domain: nil,
                txtRecord: txt
            )

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if let actualPort = newListener.port?.rawValue {
                        self.boundPort = actualPort
                    }
                case .failed(let error):
                    print("DiscoveryService listener failed: \(error)")
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { connection in
                // Reserved for transport session handoff in Milestone 3
                connection.cancel()
            }

            newListener.start(queue: queue)
        } catch {
            print("Failed to create NWListener: \(error)")
        }
    }

    private func updateTxtRecord() {
        guard let listener = listener else { return }
        let sanitizedName = localDeviceName.replacingOccurrences(of: "'", with: "")
        let serviceName = "Nearside-\(sanitizedName)"

        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["id"] = localIdentity
        txt["name"] = localDeviceName
        txt["os"] = "macos"
        txt["pair"] = "1"
        txt["recv"] = isReceivingActive ? "1" : "0"

        listener.service = NWListener.Service(
            name: serviceName,
            type: "_nearside._tcp",
            domain: nil,
            txtRecord: txt
        )
    }

    public func startBrowsing() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.setupBrowser()
        }
    }

    private func setupBrowser() {
        browser?.cancel()
        discoveredMap.removeAll()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_nearside._tcp", domain: nil)
        let parameters = NWParameters.tcp
        let newBrowser = NWBrowser(for: descriptor, using: parameters)
        self.browser = newBrowser

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            self.handleBrowseResults(results)
        }

        newBrowser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("DiscoveryService browser failed: \(error)")
            default:
                break
            }
        }

        newBrowser.start(queue: queue)
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var updatedDevices: [String: NearsideDevice] = [:]

        for result in results {
            guard case let .bonjour(txtRecord) = result.metadata else {
                continue
            }

            guard let peerId = txtRecord["id"], !peerId.isEmpty else {
                continue
            }

            // Don't show our own local device
            if !localIdentity.isEmpty && peerId == localIdentity {
                continue
            }

            let peerName = txtRecord["name"] ?? "Nearby Peer"
            let osString = txtRecord["os"] ?? "unknown"
            let recvActive = (txtRecord["recv"] == "1")

            let platform: DevicePlatform
            switch osString.lowercased() {
            case "macos": platform = .macOS
            case "android": platform = .android
            case "ios": platform = .iOS
            case "windows": platform = .windows
            case "linux": platform = .linux
            default: platform = .android
            }

            var endpointHost: String? = nil
            let endpointPort: UInt16? = nil

            if case let .service(name, _, _, _) = result.endpoint {
                endpointHost = name
            }

            let reachability: DeviceReachability = recvActive ? .online : .busy

            let device = NearsideDevice(
                id: peerId,
                name: peerName,
                platform: platform,
                fingerprint: peerId,
                ipAddress: endpointHost,
                port: endpointPort ?? 41433,
                reachability: reachability,
                lastSeen: Date()
            )

            updatedDevices[peerId] = device
        }

        self.discoveredMap = updatedDevices
        let deviceList = Array(updatedDevices.values)
        DispatchQueue.main.async { [weak self] in
            self?.onDiscoveredDevicesChanged?(deviceList)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.browser?.cancel()
            self.browser = nil
            self.discoveredMap.removeAll()
            DispatchQueue.main.async { [weak self] in
                self?.onDiscoveredDevicesChanged?([])
            }
        }
    }
}
