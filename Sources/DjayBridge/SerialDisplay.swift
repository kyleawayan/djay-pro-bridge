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

    public func send(deck1: String, deck2: String) {
        let msg = "L\(deck1)R\(deck2)\n"
        _ = msg.utf8CString.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count - 1)
        }
    }
}
