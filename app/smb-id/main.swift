// smb-id <host>: prints the SMB ServerGuid of the server at <host>, port 445.
// mountwell.sh uses it to tell two servers at the same IP apart before it mounts.
// Exit 1 when the server does not answer within 2 seconds or not with SMB2.

import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: smb-id <host>\n".utf8))
    exit(2)
}

func connect(_ host: String, timeout: Int32) -> Int32? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "445", &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(first) }
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        p = ai.pointee.ai_next
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { continue }
        // non-blocking connect, so an unreachable server costs at most `timeout` seconds
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            // refused or no route right away: try the next address, not a dead socket
            guard errno == EINPROGRESS else { close(fd); continue }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&pfd, 1, timeout * 1000) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0
            else { close(fd); continue }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
    return nil
}

// 2 seconds in all, not per read: a server sending byte by byte must not stall mountwell.sh
let deadline = Date().addingTimeInterval(2)
guard let fd = connect(CommandLine.arguments[1], timeout: 2) else { exit(1) }
defer { close(fd) }
let request = smbNegotiateRequest()
guard write(fd, request, request.count) == request.count else { exit(1) }

// the NetBIOS header says how long the answer is
var answer: [UInt8] = []
var buf = [UInt8](repeating: 0, count: 4096)
while answer.count < 4 || answer.count < 4 + (Int(answer[1]) << 16 | Int(answer[2]) << 8 | Int(answer[3])) {
    let left = Int32(deadline.timeIntervalSinceNow * 1000)
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard left > 0, poll(&pfd, 1, left) == 1 else { break }
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { break }
    answer += buf[0..<n]
    if answer.count > 65536 { break }
}
guard let guid = smbServerGUID(answer) else { exit(1) }
print(guid)
