import Foundation
import Darwin

public protocol NTFSHelperClientProtocol {
    func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse
}

/// Sets a receive/send timeout on `fileDescriptor` so socket I/O cannot block forever.
/// Mirrors `setSocketTimeouts` in `Sources/AutoVolumeNTFSHelper/main.swift`.
private func setSocketTimeouts(_ fileDescriptor: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

public struct NTFSHelperClient: NTFSHelperClientProtocol {
    private let socketPath: String

    public init(socketPath: String = NTFSHelperSocket.path) {
        self.socketPath = socketPath
    }

    public func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse {
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            return NTFSHelperResponse(success: false, message: "failed to create socket")
        }
        defer { close(clientSocket) }

        // Bound the whole mount/unmount round trip: the daemon's own 5s timeout only
        // covers its per-message socket I/O, not the subprocess it runs before
        // responding, so the client needs a longer ceiling to avoid hanging forever
        // if the daemon is slow or wedged.
        setSocketTimeouts(clientSocket, seconds: 30)

        // Writing to a socket whose peer has already closed its end raises SIGPIPE,
        // whose default disposition terminates the process. This is a shared library
        // method that may be called from multiple contexts, so it must not mutate
        // global process signal disposition (unlike the daemon's own
        // `signal(SIGPIPE, SIG_IGN)` at process entry) — SO_NOSIGPIPE scopes the
        // protection to this socket only, surfacing the failure as EPIPE instead.
        var one: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            for index in 0..<min(pathBytes.count, buffer.count) {
                buffer[index] = pathBytes[index]
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(clientSocket, sockaddrPointer, addrSize)
            }
        }
        guard connectResult == 0 else {
            return NTFSHelperResponse(success: false, message: "could not connect to NTFSPrivilegedHelper (errno \(errno))")
        }

        guard let requestData = try? NTFSHelperWireFormat.encode(request) else {
            return NTFSHelperResponse(success: false, message: "failed to encode request")
        }
        let bytesWritten = requestData.withUnsafeBytes { buffer -> Int in
            write(clientSocket, buffer.baseAddress, buffer.count)
        }
        guard bytesWritten == requestData.count else {
            return NTFSHelperResponse(success: false, message: "failed to write request")
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        guard bytesRead > 0 else {
            return NTFSHelperResponse(success: false, message: "no response from NTFSPrivilegedHelper")
        }

        guard let response = try? NTFSHelperWireFormat.decodeResponse(Data(buffer[0..<bytesRead])) else {
            return NTFSHelperResponse(success: false, message: "failed to decode response")
        }
        return response
    }
}
