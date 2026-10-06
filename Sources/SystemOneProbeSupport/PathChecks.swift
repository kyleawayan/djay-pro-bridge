import Foundation

public func ancestorDirectories(of directory: URL) -> [URL] {
    var ancestors: [URL] = []
    var current = directory.standardizedFileURL
    while true {
        ancestors.append(current)
        // Foundation appends ".." when deleting the last component of the root URL.
        if current.path == "/" { return ancestors }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path == current.path { return ancestors }
        current = parent
    }
}
