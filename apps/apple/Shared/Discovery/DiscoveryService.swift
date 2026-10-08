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
    public var onInboundConnection: ((NWConnection) -> Void)?

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
            if isReceiving {
                self.setupListener()
            } else {
                NearsideLogger.shared.info("discovery", "startAdvertising", "Dormant mode: listener not started on launch to conserve battery", state: "dormant")
            }
        }
    }

    public func updateReceivingStatus(_ isReceiving: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isReceivingActive = isReceiving
            if isReceiving {
                NearsideLogger.shared.info("discovery", "updateReceivingStatus", "Receiving activated: spinning up listener and browser", state: "active")
                self.setupListener()
                self.setupBrowser()
            } else {
                NearsideLogger.shared.info("discovery", "updateReceivingStatus", "Receiving deactivated: tearing down listener and browser for zero battery/resource consumption", state: "dormant")
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

    public func ensureBrowsingActive() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.browser == nil {
                NearsideLogger.shared.debug("discovery", "ensureBrowsingActive", "Spinning up browser on-demand for outbound discovery", state: "browsing")
                self.setupBrowser()
            }
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
                        NearsideLogger.shared.info("discovery", "setupListener", "Discovery listener bound to port \(actualPort)", state: "advertising")
                    }
                case .failed(let error):
                    let err = NearsideError(code: .discoveryRegistrationFailed, operation: "setupListener", message: "Discovery listener failed", underlyingError: error)
                    NearsideLogger.shared.error(err, state: "failed")
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                if let handler = self.onInboundConnection {
                    handler(connection)
                } else {
                    connection.cancel()
                }
            }

            newListener.start(queue: queue)
        } catch {
            let err = NearsideError(code: .discoveryRegistrationFailed, operation: "setupListener", message: "Failed to create NWListener", underlyingError: error)
            NearsideLogger.shared.error(err, state: "failed")
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
            case .ready:
                NearsideLogger.shared.info("discovery", "setupBrowser", "mDNS browser ready for _nearside._tcp", state: "browsing")
            case .failed(let error):
                let err = NearsideError(code: .discoveryBrowserFailed, operation: "setupBrowser", message: "Discovery browser failed", underlyingError: error)
                NearsideLogger.shared.error(err, state: "failed")
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

    public func findDiscoveredDevice(identity: String) -> NearsideDevice? {
        return queue.sync {
            discoveredMap[identity] ?? discoveredMap.values.first(where: { $0.id == identity || $0.fingerprint == identity })
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
