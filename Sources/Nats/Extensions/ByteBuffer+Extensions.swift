// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

extension ByteBuffer {
    /// Get all readable bytes as Data without consuming them
    @inlinable
    func getData() -> Data? {
        guard let bytes = getBytes(at: readerIndex, length: readableBytes) else {
            return nil
        }
        return Data(bytes)
    }

    /// Read all remaining bytes as Data
    @inlinable
    mutating func readData() -> Data? {
        guard let bytes = readBytes(length: readableBytes) else {
            return nil
        }
        return Data(bytes)
    }

    /// Create a ByteBuffer from Data
    @inlinable
    static func from(_ data: Data, allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    /// Create a ByteBuffer from a string
    @inlinable
    static func from(_ string: String, allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }

    /// Peek at bytes without consuming them
    @inlinable
    func peekBytes(count: Int) -> [UInt8]? {
        guard readableBytes >= count else { return nil }
        return getBytes(at: readerIndex, length: count)
    }

    /// Peek at a string without consuming it
    @inlinable
    func peekString(length: Int) -> String? {
        guard readableBytes >= length else { return nil }
        return getString(at: readerIndex, length: length)
    }

    /// Check if buffer starts with given bytes
    @inlinable
    func startsWith(_ bytes: [UInt8]) -> Bool {
        guard readableBytes >= bytes.count else { return false }
        guard let bufferBytes = peekBytes(count: bytes.count) else { return false }
        return bufferBytes == bytes
    }

    /// Check if buffer starts with given string
    @inlinable
    func startsWith(_ string: String) -> Bool {
        startsWith(Array(string.utf8))
    }

    /// Find index of byte sequence
    func find(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty, readableBytes >= bytes.count else { return nil }

        let endIndex = readerIndex + readableBytes - bytes.count

        outer: for i in readerIndex...endIndex {
            for (j, byte) in bytes.enumerated() {
                guard getInteger(at: i + j, as: UInt8.self) == byte else {
                    continue outer
                }
            }
            return i - readerIndex
        }

        return nil
    }

    /// Find index of CRLF
    func findCRLF() -> Int? {
        find([0x0D, 0x0A])
    }
}

// MARK: - Data Extensions

extension Data {
    /// Convert to ByteBuffer
    @inlinable
    func toByteBuffer(allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        ByteBuffer.from(self, allocator: allocator)
    }
}

// MARK: - String Extensions

extension String {
    /// Convert to ByteBuffer
    @inlinable
    func toByteBuffer(allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        ByteBuffer.from(self, allocator: allocator)
    }
}
