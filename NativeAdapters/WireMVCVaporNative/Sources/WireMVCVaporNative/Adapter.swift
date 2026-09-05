// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-performance project authors

public import HTTPAPIs
public import HTTPTypes
public import Vapor
public import WireMVC

public import BasicContainers
public import NIOCore

// Mount WireMVC's collated routes on Vapor's own router.
//
// Same shape as the Hummingbird adapter: for a one-shot response the handler runs to completion **inside**
// Vapor's route closure, writing head and body into a collector, and the closure returns a `Response` built
// from them. No unstructured task, no rendezvous channel, no OpenAPI currency types.
//
// Vapor differs in two ways that matter. Its response head is NIOHTTP1's `HTTPHeaders` rather than
// HTTPTypes' `HTTPFields`, so heads convert at the boundary. And its route closures are `async` over a
// future-based responder chain — the same `async`/`EventLoopFuture` boundary measured at ~16 µs per
// `AsyncMiddleware` — which this adapter crosses once per request and cannot avoid.

/// Vapor supplies no per-request capabilities WireMVC reads, so the context is empty.
public struct VaporRequestContext: HTTPServerCapability.RequestContext {
    public init() {}
}

/// An `AsyncReader` over the body Vapor has already collected.
///
/// Vapor buffers a request body before invoking a non-streaming route, so there is nothing left to stream:
/// this delivers it as one chunk and then end-of-stream. That is a real difference from the native path,
/// where a streaming binding sees bytes as they arrive — worth knowing before reading anything into an
/// upload benchmark, and irrelevant to the empty bodies measured here.
public struct VaporReader: AsyncReader {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = any Error
    public typealias FinalElement = HTTPFields?
    public typealias Buffer = UniqueArray<UInt8>

    private let source: CollectedBody

    public init(_ buffer: ByteBuffer?) { source = CollectedBody(buffer) }

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        let chunk = source.take()
        var buffer = chunk.map { Buffer(copying: Array(buffer: $0)) } ?? Buffer()
        do {
            return try await body(&buffer, chunk == nil ? .some(nil) : nil)
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// Hands the collected body over exactly once; every later read reports end-of-stream.
private final class CollectedBody: @unchecked Sendable {
    private var buffer: ByteBuffer?
    init(_ buffer: ByteBuffer?) { self.buffer = buffer?.readableBytes == 0 ? nil : buffer }
    func take() -> ByteBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// What a native-mounted Vapor route refuses to serve. See the Hummingbird adapter: a streamed response
/// needs the handler to outlive the closure that produced the head, which is the shape being avoided.
public enum WireMVCVaporNativeError: Error, CustomStringConvertible {
    case streamingNotSupported

    public var description: String {
        "A streamed response is not supported by the native Vapor adapter prototype."
    }
}

/// Where a response lands before the route closure returns it.
final class VaporResponseCollector: @unchecked Sendable {
    var head: HTTPResponse?
    var body: ByteBuffer = ByteBuffer()
}

public struct VaporResponseSender: HTTPResponseSender {
    public typealias Writer = VaporWriter

    let collector: VaporResponseCollector

    public mutating func sendInformational(_ response: HTTPResponse) async throws {}

    public consuming func send(_ response: HTTPResponse) async throws -> VaporWriter {
        throw WireMVCVaporNativeError.streamingNotSupported
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        collector.head = response
        collector.body.reserveCapacity(buffer.count)
        var consumer = buffer.consumeAll()
        while let byte = consumer.next() { collector.body.writeInteger(byte) }
    }
}

/// Unreachable in the prototype — `send(_:)` throws before returning one.
public struct VaporWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = any Error
    public typealias FinalElement = HTTPFields?

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(any Error) where Buffer.Element: ~Copyable {
        throw WireMVCVaporNativeError.streamingNotSupported
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(any Error) where Buffer.Element: ~Copyable {
        throw WireMVCVaporNativeError.streamingNotSupported
    }
}
