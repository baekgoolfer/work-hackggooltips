import Foundation
import Darwin

// =====================================================================================
// libproc helpers for meeting detection (no permission needed for same-user processes).
//
//   udpSockets(of:)      UDP sockets of one pid via proc_pidinfo(PROC_PIDLISTFDS) + proc_pidfdinfo(SOCKETINFO).
//                        Matches `lsof -nP -iUDP -a -p <pid>` exactly (checked against Chrome's network service).
//   countedUDP(of:)      what the Zoom rule uses: UDP sockets of the Zoom MAIN pid (idle = 0, in a meeting >= 1).
//                        mDNS (port 5353) is ignored. Never count helper processes: ZoomCefHelper (an embedded
//                        Chromium network service) holds unrelated QUIC sockets even when idle.
//   childPIDs / arguments / chromiumRole / hasMeetingKeyArgument   diagnostics for `probe` (L-01, L-05, L-17).
// =====================================================================================

struct UDPSocketInfo: Codable, Equatable {
    var localPort: UInt16
    var remotePort: UInt16          // 0 when the socket is not connected
    var isIPv4: Bool
    var isConnected: Bool { remotePort != 0 }
}

enum NetworkProbe {
    static let mdnsPort: UInt16 = 5353
    /// Documented Teams media relay ports (UDP 3478-3481). Shown by `probe` only; not used by the call formula (L-06).
    static let teamsRelayPorts: ClosedRange<UInt16> = 3478...3481

    // MARK: UDP sockets

    /// nil when the pid cannot be inspected (exited, other user). A live process always has open descriptors, so
    /// "0 bytes needed" is an error (ESRCH), not "no sockets".
    static func udpSockets(of pid: pid_t) -> [UDPSocketInfo]? {
        guard pid > 0 else { return nil }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(needed) / stride + 8                    // fds may be opened between the two calls
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * stride))
        guard got > 0 else { return nil }
        var sockets: [UDPSocketInfo] = []
        for i in 0..<(Int(got) / stride) where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let s = info.psi
            guard s.soi_kind == Int32(SOCKINFO_IN), s.soi_protocol == IPPROTO_UDP else { continue }
            let inet = s.soi_proto.pri_in
            sockets.append(UDPSocketInfo(localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)),
                                         remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport)),
                                         isIPv4: (Int32(inet.insi_vflag) & INI_IPV4) != 0))
        }
        return sockets
    }

    /// Sockets that count as call media (everything except mDNS).
    static func counted(_ sockets: [UDPSocketInfo]) -> Int {
        return sockets.filter { $0.localPort != mdnsPort && $0.remotePort != mdnsPort }.count
    }

    static func countedUDP(of pid: pid_t) -> Int? {
        return udpSockets(of: pid).map(counted)
    }

    /// Connected sockets whose remote port is in `ports` (Teams relay check shown by `probe`).
    static func connected(_ sockets: [UDPSocketInfo], toPorts ports: ClosedRange<UInt16>) -> Int {
        return sockets.filter { $0.isConnected && ports.contains($0.remotePort) }.count
    }

    /// "443x6" style histogram of the remote ports of connected sockets, plus the number of unconnected ones.
    static func describe(_ sockets: [UDPSocketInfo]) -> String {
        var histogram: [UInt16: Int] = [:]
        for s in sockets where s.isConnected { histogram[s.remotePort, default: 0] += 1 }
        let remote = histogram.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        let unconnected = sockets.filter { !$0.isConnected }.map { Int($0.localPort) }.sorted()
        let local = unconnected.prefix(8).map(String.init).joined(separator: ",") + (unconnected.count > 8 ? ",..." : "")
        return "total=\(sockets.count) connected=\(sockets.count - unconnected.count) remote-ports=[\(remote)] unconnected-local-ports=[\(local)]"
    }

    // MARK: Process inspection (probe diagnostics)

    static func childPIDs(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 1024)
        let result = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }
        return Array(buffer.prefix(while: { $0 > 0 }))          // zero-terminated; independent of what `result` counts
    }

    /// Last path component of the executable ("ZoomCefHelper (GPU)"), "?" when unknown.
    static func executableName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "?" }
        let path = String(cString: buffer)
        return path.split(separator: "/").last.map(String.init) ?? "?"
    }

    /// argv via sysctl(KERN_PROCARGS2); nil if unreadable.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        var argc: Int32 = 0
        memcpy(&argc, buffer, 4)
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }             // exec path
        while i < size && buffer[i] == 0 { i += 1 }             // NUL padding
        var args: [String] = []
        var start = i
        while i < size && args.count < Int(argc) {
            if buffer[i] == 0 {
                args.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    enum ChromiumRole: String, Codable {
        case main, audioService = "audio-service", videoCapture = "video-capture", network, gpu, renderer, otherUtility = "other-utility"
    }

    static func chromiumRole(arguments args: [String]) -> ChromiumRole {
        guard let type = args.first(where: { $0.hasPrefix("--type=") }) else { return .main }
        switch type {
        case "--type=renderer": return .renderer
        case "--type=gpu-process": return .gpu
        case "--type=utility":
            let sub = args.first(where: { $0.hasPrefix("--utility-sub-type=") }) ?? ""
            if sub.hasSuffix("audio.mojom.AudioService") { return .audioService }
            if sub.hasSuffix("video_capture.mojom.VideoCaptureService") { return .videoCapture }
            if sub.hasSuffix("network.mojom.NetworkService") { return .network }
            return .otherUtility
        default: return .otherUtility
        }
    }

    /// True when argv contains `-key <8+ digits>` (older Zoom builds put the meeting id there; L-05). The digits are
    /// never returned or printed: they are the meeting id.
    static func hasMeetingKeyArgument(_ args: [String]) -> Bool {
        for (i, a) in args.enumerated() where a == "-key" && i + 1 < args.count {
            let v = args[i + 1]
            if v.count >= 8, v.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        }
        return false
    }
}
