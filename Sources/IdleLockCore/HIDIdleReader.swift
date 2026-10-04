import Foundation
import IOKit

public protocol IdleTimeReading {
    func idleSeconds() throws -> TimeInterval
}

public final class HIDIdleReader: IdleTimeReading {
    public init() {}

    public func idleSeconds() throws -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else {
            throw IdleLockError.hidServiceUnavailable
        }
        defer {
            IOObjectRelease(service)
        }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            throw IdleLockError.hidIdlePropertyUnavailable
        }

        if let number = value as? NSNumber {
            return number.doubleValue / 1_000_000_000
        }

        if let data = value as? Data, data.count >= MemoryLayout<UInt64>.size {
            let nanoseconds = data.withUnsafeBytes { pointer -> UInt64 in
                pointer.load(as: UInt64.self)
            }
            return TimeInterval(nanoseconds) / 1_000_000_000
        }

        throw IdleLockError.unsupportedHIDIdleValue
    }
}
