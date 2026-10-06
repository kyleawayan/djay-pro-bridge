import Foundation
import CoreFoundation

public enum CaptureCounters {
    public enum ValidationError: Error { case invalidLength, overflow }

    public static func add(_ rawLength: Any?, to total: Int) throws -> Int {
        guard let number = rawLength as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let length = Int(number.stringValue), length >= 0, total >= 0 else {
            throw ValidationError.invalidLength
        }
        let (result, overflow) = total.addingReportingOverflow(length)
        guard !overflow else { throw ValidationError.overflow }
        return result
    }
}
