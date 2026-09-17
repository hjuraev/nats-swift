// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Parses the timestamps the server writes: RFC 3339 with optional fractional
/// seconds, `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
///
/// `ISO8601DateFormatter` is expensive to create and was created per value:
/// once per `KeyValueBucket.get` for the `Nats-Time-Stamp` header (~130 µs on
/// Linux, most of the time a get took) and once per date field in every API
/// response. This reads the bytes directly and falls back to the formatter
/// only for forms it does not recognise.
enum RFC3339 {
    /// The date `string` spells, or nil if it is not a timestamp in either
    /// the fast form or one `ISO8601DateFormatter` accepts.
    static func date(from string: String) -> Date? {
        if let date = fastDate(from: string) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// The fast path alone: nil for anything outside the exact form above.
    static func fastDate(from string: String) -> Date? {
        var bytes = string.utf8.makeIterator()

        func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let byte = bytes.next() else { return nil }
                let digit = byte &- UInt8(ascii: "0")
                guard digit < 10 else { return nil }
                value = value * 10 + Int(digit)
            }
            return value
        }
        func expect(_ ascii: Unicode.Scalar) -> Bool {
            bytes.next() == UInt8(ascii: ascii)
        }

        guard let year = digits(4), expect("-"),
              let month = digits(2), expect("-"),
              let day = digits(2) else { return nil }
        guard let separator = bytes.next(), separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " ") else {
            return nil
        }
        guard let hour = digits(2), expect(":"),
              let minute = digits(2), expect(":"),
              let second = digits(2) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60 else { return nil }

        // Fraction, up to nanoseconds; further digits are read and ignored.
        var nanoseconds = 0
        var next = bytes.next()
        if next == UInt8(ascii: ".") {
            var scale = 100_000_000
            var sawDigit = false
            next = bytes.next()
            while let byte = next, byte &- UInt8(ascii: "0") < 10 {
                nanoseconds += Int(byte &- UInt8(ascii: "0")) * scale
                scale /= 10
                sawDigit = true
                next = bytes.next()
            }
            guard sawDigit else { return nil }
        }

        var offsetSeconds = 0
        switch next {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            break
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign = next == UInt8(ascii: "-") ? -1 : 1
            guard let offsetHours = digits(2), expect(":"), let offsetMinutes = digits(2),
                  offsetHours < 24, offsetMinutes < 60 else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        default:
            return nil
        }
        guard bytes.next() == nil else { return nil }

        let days = daysSinceEpoch(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    /// Days from 1970-01-01 to the given proleptic Gregorian date.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
