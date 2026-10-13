import MultipeerConnectivity
import UIKit

struct PlayerState: Codable {
    var cx: Float, cy: Float, ca: Float      // chassis
    var w1x: Float, w1y: Float               // wheel 1
    var w2x: Float, w2y: Float               // wheel 2
    var tx: Float, ty: Float, ta: Float      // torso
    var hx: Float, hy: Float                 // head
    var status: Int                          // 0 riding, 1 dead, 2 finished
}

/// kind 0 = state update, kind 1 = "I finished the race"
struct Packet: Codable {
    var kind: Int
    var state: PlayerState?
}

final class LAN: NSObject, ObservableObject {
    enum Mode { case idle, hosting, joining }

    @Published var mode: Mode = .idle
    @Published var connected = false
    @Published var hosts: [MCPeerID] = []
    var onPacket: ((Packet) -> Void)?

    private let serviceType = "wobble-wheels"   // must match Info.plist Bonjour entries
    private let me = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    func host() {
        reset()
        mode = .hosting
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    func join() {
        reset()
        mode = .joining
        browser = MCNearbyServiceBrowser(peer: me, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    func stop() {
        reset()
        mode = .idle
    }

    func send(_ packet: Packet, reliable: Bool) {
        guard connected, let session = session, !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(packet) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: reliable ? .reliable : .unreliable)
    }

    private func reset() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session?.disconnect()
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        connected = false
        hosts = []
    }
}

extension LAN: MCSessionDelegate {
    func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard s === self.session else { return }
            self.connected = (state == .connected)
            if state == .connected {
                self.advertiser?.stopAdvertisingPeer()
                self.browser?.stopBrowsingForPeers()
            }
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let p = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        DispatchQueue.main.async { self.onPacket?(p) }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LAN: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { invitationHandler(true, self.session) }
    }
}

extension LAN: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.hosts.contains(peerID) { self.hosts.append(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.hosts.removeAll { $0 == peerID } }
    }
}
