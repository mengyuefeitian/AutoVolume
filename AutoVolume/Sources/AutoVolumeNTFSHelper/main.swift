import Foundation
import Darwin
import AutoVolumeShared

let socketPath = NTFSHelperSocket.path
unlink(socketPath)

let serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverSocket >= 0 else {
    fputs("NTFSPrivilegedHelper: failed to create socket (errno \(errno))\n", stderr)
    exit(1)
}

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
let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(serverSocket, sockaddrPointer, addrSize)
    }
}
guard bindResult == 0 else {
    fputs("NTFSPrivilegedHelper: bind failed (errno \(errno))\n", stderr)
    exit(1)
}
chmod(socketPath, 0o666)
guard listen(serverSocket, 8) == 0 else {
    fputs("NTFSPrivilegedHelper: listen failed (errno \(errno))\n", stderr)
    exit(1)
}

let mountPlanner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)
let commandRunner = ProcessCommandRunner()

func peerUID(of fileDescriptor: Int32) -> uid_t? {
    var credential = xucred()
    var credentialSize = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fileDescriptor, 0, LOCAL_PEERCRED, &credential, &credentialSize) == 0 else { return nil }
    return credential.cr_uid
}

func respond(_ response: NTFSHelperResponse, on clientSocket: Int32) {
    guard let encoded = try? NTFSHelperWireFormat.encode(response) else { return }
    encoded.withUnsafeBytes { buffer in
        _ = write(clientSocket, buffer.baseAddress, buffer.count)
    }
}

/// Defense-in-depth check on top of `NTFSHelperRequestValidator.validate(_:)`.
///
/// The validator only checks that `mountPoint` has the string *prefix* `/Volumes/` —
/// it does not canonicalize the path. `"/Volumes/../etc/passwd".hasPrefix("/Volumes/")`
/// is `true` in Swift, so a malicious or buggy caller could get a path outside
/// `/Volumes` past that check. Since this process runs as root and is the one that
/// actually acts on the path (passing it to `diskutil unmount` / `ntfs-3g` as the
/// mount point), it must not trust the validator's prefix check alone. We
/// canonicalize the path here and re-verify the *canonicalized* result is still
/// confined to `/Volumes/` before it is used for anything.
func canonicalizedMountPointUnderVolumes(_ rawMountPoint: String) -> String? {
    let canonicalized = URL(fileURLWithPath: rawMountPoint).standardizedFileURL.path
    guard canonicalized.hasPrefix("/Volumes/"), canonicalized != "/Volumes/" else { return nil }
    return canonicalized
}

/// Defense-in-depth check on `devicePath`: `NTFSHelperRequestValidator` only checks
/// that a mount request has a non-nil `devicePath`, it never inspects its content.
/// Since `devicePath` is fed directly to `ntfs-3g` as an argument by a root process,
/// require it to look like a BSD disk device node (`/dev/diskNsN`, optionally with
/// a trailing partition/slice suffix) before acting on it, rather than trusting an
/// arbitrary caller-supplied string.
func isPlausibleDiskDevicePath(_ devicePath: String) -> Bool {
    let pattern = #"^/dev/disk[0-9]+(s[0-9]+)?$"#
    return devicePath.range(of: pattern, options: .regularExpression) != nil
}

func handle(clientSocket: Int32) {
    defer { close(clientSocket) }

    guard let uid = peerUID(of: clientSocket), uid != 0 else {
        respond(NTFSHelperResponse(success: false, message: "unauthorized"), on: clientSocket)
        return
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(clientSocket, &buffer, buffer.count)
    guard bytesRead > 0 else { return }
    let requestData = Data(buffer[0..<bytesRead])

    do {
        let request = try NTFSHelperWireFormat.decodeRequest(requestData)
        if let validationError = NTFSHelperRequestValidator.validate(request) {
            respond(NTFSHelperResponse(success: false, message: validationError), on: clientSocket)
            return
        }

        guard let mountPoint = canonicalizedMountPointUnderVolumes(request.mountPoint) else {
            respond(NTFSHelperResponse(success: false, message: "mountPoint must canonicalize to a path under /Volumes"), on: clientSocket)
            return
        }

        switch request.action {
        case .mount:
            guard let devicePath = request.devicePath else {
                respond(NTFSHelperResponse(success: false, message: "devicePath is required for mount"), on: clientSocket)
                return
            }
            guard isPlausibleDiskDevicePath(devicePath) else {
                respond(NTFSHelperResponse(success: false, message: "devicePath must be a /dev/diskN device node"), on: clientSocket)
                return
            }
            _ = try? commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: mountPoint))
            let mountResult = try commandRunner.run(mountPlanner.mountReadWritePlan(devicePath: devicePath, mountPoint: mountPoint))
            respond(NTFSHelperResponse(success: mountResult.exitCode == 0, message: mountResult.stderr), on: clientSocket)
        case .unmount:
            let result = try commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: mountPoint))
            respond(NTFSHelperResponse(success: result.exitCode == 0, message: result.stderr), on: clientSocket)
        }
    } catch {
        respond(NTFSHelperResponse(success: false, message: error.localizedDescription), on: clientSocket)
    }
}

while true {
    let clientSocket = accept(serverSocket, nil, nil)
    guard clientSocket >= 0 else { continue }
    handle(clientSocket: clientSocket)
}
