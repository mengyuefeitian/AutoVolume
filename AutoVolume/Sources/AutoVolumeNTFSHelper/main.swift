import Foundation
import Darwin
import SystemConfiguration
import AutoVolumeShared

/// Minimal audit-trail logging. Matches the simplicity of this project's existing
/// logging (plain `fputs` to stderr, no logging dependency). `stderr` is redirected
/// to a durable log file via `StandardErrorPath` in the LaunchDaemon plist.
func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[\(timestamp)] NTFSPrivilegedHelper: \(message)\n", stderr)
}

// Writing to a socket whose peer has already closed its end raises SIGPIPE, whose
// default disposition terminates the process. Ignore it so `write()` instead
// reports the failure via its return value/errno, keeping the daemon alive.
signal(SIGPIPE, SIG_IGN)

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
log("listening on \(socketPath)")

let mountPlanner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)
let commandRunner = ProcessCommandRunner()

func peerUID(of fileDescriptor: Int32) -> uid_t? {
    var credential = xucred()
    var credentialSize = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fileDescriptor, 0, LOCAL_PEERCRED, &credential, &credentialSize) == 0 else { return nil }
    return credential.cr_uid
}

/// The UID of the currently logged-in console (GUI-session) user, or `nil` if it
/// can't be determined (e.g. no one is logged in at the console).
func consoleUserUID() -> uid_t? {
    var uid: uid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
    return uid
}

/// Sets a receive/send timeout on an accepted client socket so a client that
/// connects and then sends nothing (or reads nothing) cannot wedge this
/// single-threaded daemon forever and starve every subsequent connection.
func setSocketTimeouts(_ fileDescriptor: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
    // `standardizedFileURL` only does lexical normalization (collapsing "..",
    // "." etc.) — it does not resolve symlinks. A symlink physically located
    // under /Volumes could still lexically stand for a path outside it, so also
    // resolve symlinks and re-check the result. (Low severity in practice: /Volumes
    // itself is root-owned 0755, so planting such a symlink already requires root —
    // but this check is cheap, so we do it anyway.)
    let standardized = URL(fileURLWithPath: rawMountPoint).standardizedFileURL.path
    guard standardized.hasPrefix("/Volumes/"), standardized != "/Volumes/" else { return nil }
    let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    guard resolved.hasPrefix("/Volumes/"), resolved != "/Volumes/" else { return nil }
    return standardized
}

/// Defense-in-depth check on `devicePath`: `NTFSHelperRequestValidator` only checks
/// that a mount request has a non-nil `devicePath`, it never inspects its content.
/// Since `devicePath` is fed directly to `ntfs-3g` as an argument by a root process,
/// require it to look like a BSD disk device node (`/dev/diskNsN`, optionally with
/// a trailing partition/slice suffix) before acting on it, rather than trusting an
/// arbitrary caller-supplied string.
func isPlausibleDiskDevicePath(_ devicePath: String) -> Bool {
    let pattern = #"^/dev/disk[0-9]+(s[0-9]+)?$"#
    // ICU's `$` can match immediately before a trailing line terminator rather than
    // strictly at the end of the string (e.g. "/dev/disk4\n" could satisfy a naive
    // `$`-anchored match). Not exploitable downstream today (ntfs-3g just fails on a
    // bad path), but require the match to span the *entire* string so this can't
    // silently regress if the caller/wire format ever changes.
    guard let range = devicePath.range(of: pattern, options: .regularExpression) else { return false }
    return range == devicePath.startIndex..<devicePath.endIndex
}

func handle(clientSocket: Int32) {
    defer { close(clientSocket) }
    setSocketTimeouts(clientSocket, seconds: 5)

    guard let uid = peerUID(of: clientSocket) else {
        log("rejected connection: unable to read peer credentials")
        respond(NTFSHelperResponse(success: false, message: "unauthorized"), on: clientSocket)
        return
    }

    // Positive allowlist: only the currently logged-in console (GUI-session) user
    // may issue mount/unmount requests. `uid != 0` alone (the prior check) let any
    // local non-root process on the machine — not just the AutoVolume app — drive
    // this root-owned daemon, since the socket is world-accessible (chmod 0666).
    //
    // At the login window (no one signed in yet), `SCDynamicStoreCopyConsoleUser`
    // does not return nil — it returns "loginwindow" with uid 0. Explicitly exclude
    // that (`consoleUID != 0`) so this case is treated the same as "console user
    // can't be determined" rather than degenerating into "peer must be uid 0",
    // which would silently readmit the very root-peer case the original check
    // existed to reject.
    guard let consoleUID = consoleUserUID(), consoleUID != 0, uid == consoleUID else {
        log("rejected connection from uid \(uid): does not match console user")
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
            log("rejected \(request.action) request for \(request.mountPoint): \(validationError)")
            respond(NTFSHelperResponse(success: false, message: validationError), on: clientSocket)
            return
        }

        guard let mountPoint = canonicalizedMountPointUnderVolumes(request.mountPoint) else {
            log("rejected \(request.action) request: mountPoint \(request.mountPoint) does not canonicalize under /Volumes")
            respond(NTFSHelperResponse(success: false, message: "mountPoint must canonicalize to a path under /Volumes"), on: clientSocket)
            return
        }

        switch request.action {
        case .mount:
            guard let devicePath = request.devicePath else {
                log("rejected mount request for \(mountPoint): devicePath missing")
                respond(NTFSHelperResponse(success: false, message: "devicePath is required for mount"), on: clientSocket)
                return
            }
            guard isPlausibleDiskDevicePath(devicePath) else {
                log("rejected mount request for \(mountPoint): devicePath \(devicePath) is not a plausible disk device")
                respond(NTFSHelperResponse(success: false, message: "devicePath must be a /dev/diskN device node"), on: clientSocket)
                return
            }
            _ = try? commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: mountPoint))
            let mountResult = try commandRunner.run(mountPlanner.mountReadWritePlan(devicePath: devicePath, mountPoint: mountPoint))
            let success = mountResult.exitCode == 0
            log("mount \(devicePath) -> \(mountPoint): \(success ? "success" : "failed (\(mountResult.stderr))")")
            respond(NTFSHelperResponse(success: success, message: mountResult.stderr), on: clientSocket)
        case .unmount:
            let result = try commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: mountPoint))
            let success = result.exitCode == 0
            log("unmount \(mountPoint): \(success ? "success" : "failed (\(result.stderr))")")
            respond(NTFSHelperResponse(success: success, message: result.stderr), on: clientSocket)
        }
    } catch {
        log("error handling request: \(error.localizedDescription)")
        respond(NTFSHelperResponse(success: false, message: error.localizedDescription), on: clientSocket)
    }
}

while true {
    let clientSocket = accept(serverSocket, nil, nil)
    guard clientSocket >= 0 else { continue }
    handle(clientSocket: clientSocket)
}
