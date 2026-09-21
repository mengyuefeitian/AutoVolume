import Foundation
import Darwin

public protocol NTFSHelperClientProtocol {
    func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse
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
