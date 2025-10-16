// ClockSync.swift
import Foundation
import Combine

/// Simple model for clock pong messages (must match WebSocketManager).
/// WebSocketManager should publish these from the "clockPong" WS message.
//struct ClockPong {
//    let serverTime: TimeInterval          // seconds since epoch (from server)
//    let echoClientTime: TimeInterval?     // server echoes our clientTime (optional)
//}

/// Estimates server clock offset so listeners can sync to a DJ.
/// offset = (estimated server "now") - (client now)
final class ClockSync: ObservableObject {

    private let ws: WebSocketManager
    private var bag = Set<AnyCancellable>()

    // Public estimates (seconds)
    @Published private(set) var offset: Double = 0      // serverTime - clientNow
    @Published private(set) var jitter: Double = 0      // median RTT

    // Internal sampling
    private var samples: [Double] = []
    private var rtts: [Double] = []

    init(ws: WebSocketManager) {
        self.ws = ws
        bind()
    }

    private func bind() {
        ws.clockPongPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (pong: ClockPong) in
                self?.process(pong)
            }
            .store(in: &bag)
    }

    /// Take N samples spaced by `interval` seconds.
    func performSync(samplesCount: Int = 8, interval: TimeInterval = 0.2) {
        samples.removeAll()
        rtts.removeAll()

        // Fire first ping immediately, then schedule the rest.
        sendPing()

        guard samplesCount > 1 else { return }
        for i in 1..<samplesCount {
            let delay = interval * Double(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        // WebSocketManager should implement this to send:
        // { type: "clockPing", payload: { clientTime: now } }
        ws.sendClockPing()
    }

    private func process(_ pong: ClockPong) {
        // Times are in seconds since epoch
        let t_client_recv = Date().timeIntervalSince1970
        // Use echoed clientTime if present; else fall back to "now" to avoid NaN
        let t_client_send = pong.echoClientTime ?? t_client_recv
        let t_server_recv = pong.serverTime

        // RTT ~= (client_recv - client_send)
        let rtt = max(0, t_client_recv - t_client_send)
        let oneWay = rtt / 2.0

        // Server "now" as seen by client upon receipt (server timestamp + one-way latency)
        let est_server_now = t_server_recv + oneWay

        // Offset = server_now - client_now
        let sampleOffset = est_server_now - t_client_recv

        samples.append(sampleOffset)
        rtts.append(rtt)

        // Robust aggregation: median offset, median rtt
        let sortedOffsets = samples.sorted()
        let sortedRTTs = rtts.sorted()
        let midO = sortedOffsets.count / 2
        let midR = sortedRTTs.count / 2

        let medianOffset: Double
        if sortedOffsets.count % 2 == 0 {
            medianOffset = (sortedOffsets[midO - 1] + sortedOffsets[midO]) / 2.0
        } else {
            medianOffset = sortedOffsets[midO]
        }

        let medianRTT: Double
        if sortedRTTs.count % 2 == 0 {
            medianRTT = (sortedRTTs[midR - 1] + sortedRTTs[midR]) / 2.0
        } else {
            medianRTT = sortedRTTs[midR]
        }

        offset = medianOffset
        jitter = medianRTT
        // print("⏱ offset=\(offset)s jitter=\(jitter)s rtt=\(rtt)s")
    }
}
