import Foundation

public class SerialDisplay {
    private let fd: Int32

    public init?(port: String) {
        let fd = open(port, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            printError("SerialDisplay: failed to open \(port)")
            return nil
        }

        // Clear non-blocking now that we've opened
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        // Configure 9600 8N1
        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, speed_t(B9600))
        cfsetospeed(&options, speed_t(B9600))
        options.c_cflag |= UInt(CS8 | CLOCAL)
        options.c_cflag &= ~UInt(PARENB | CSTOPB)
        tcsetattr(fd, TCSANOW, &options)

        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Send display state: D<bj1>,<lp1>,<lp2>,<bj2>,<l1on>,<l2on>
    public func sendState(bj1: String, lp1: String, lp2: String, bj2: String, loop1On: Bool, loop2On: Bool) {
        let msg = "D\(bj1),\(lp1),\(lp2),\(bj2),\(loop1On ? 1 : 0),\(loop2On ? 1 : 0)\n"
        writeString(msg)
    }

    /// Send persistent overlay: O<text> (stays until cleared)
    public func sendOverlay(_ text: String) {
        writeString("O\(text)\n")
    }

    /// Clear overlay
    public func clearOverlay() {
        writeString("C\n")
    }

    private func writeString(_ msg: String) {
        _ = msg.utf8CString.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count - 1)
        }
    }
}
