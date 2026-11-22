import Compression
import Foundation

// Un marco de aplicación (JSON, hasta 16 MiB) se parte en trozos que entran en un mensaje de Noise (spec P.5). El
// texto plano de cada trozo es `flags(u8) ‖ len(u16 BE) ‖ datos ‖ ceros` hasta un múltiplo de 256 (máx. 65 280).
// `flags`: bit 0 = siguen más trozos, bit 1 = el marco va comprimido (zlib/deflate, en todos sus trozos).

public enum FramingError: Error, Equatable, Sendable {
    case tooLarge
    case malformed
}

public enum FrameChunker {
    public static let maxFrameSize = 16 << 20
    public static let block = 256
    public static let maxChunkPlaintext = 65_280
    public static let maxChunkData = maxChunkPlaintext - 3

    static let more: UInt8 = 0b01
    static let compressed: UInt8 = 0b10

    public static func chunks(for data: Data, compress: Bool) throws -> [Data] {
        guard data.count <= maxFrameSize else { throw FramingError.tooLarge }
        let payload = compress ? try Zlib.compress(data) : data
        var chunks: [Data] = []
        var offset = payload.startIndex
        repeat {
            let end = min(offset + maxChunkData, payload.endIndex)
            let piece = payload[offset..<end]
            var flags: UInt8 = compress ? compressed : 0
            if end < payload.endIndex { flags |= more }
            var chunk = Data(capacity: maxChunkPlaintext)
            chunk.append(flags)
            chunk.append(Data(uint16BE: UInt16(piece.count)))
            chunk.append(piece)
            chunk.append(Data(count: (block - chunk.count % block) % block))
            chunks.append(chunk)
            offset = end
        } while offset < payload.endIndex
        return chunks
    }
}

/// Rearma un marco. Falla apenas lo acumulado pasa el tope (no guarda de más) y nunca infla más de 16 MiB.
public struct FrameAssembler: Sendable {
    private var buffer = Data()
    private var compressed: Bool?

    public init() {}

    /// Devuelve el marco cuando llega el último trozo; `nil` mientras falten.
    public mutating func add(_ chunk: Data) throws -> Data? {
        guard chunk.count >= FrameChunker.block, chunk.count <= FrameChunker.maxChunkPlaintext,
              chunk.count % FrameChunker.block == 0 else { throw FramingError.malformed }
        let flags = chunk[chunk.startIndex]
        guard flags & ~(FrameChunker.more | FrameChunker.compressed) == 0 else { throw FramingError.malformed }
        let isCompressed = flags & FrameChunker.compressed != 0
        if let compressed, compressed != isCompressed { throw FramingError.malformed }
        compressed = isCompressed
        let length = Int(chunk.readBE(at: 1, count: 2))
        guard length <= chunk.count - 3 else { throw FramingError.malformed }
        let body = chunk.dropFirst(3)
        guard body.dropFirst(length).allSatisfy({ $0 == 0 }) else { throw FramingError.malformed }
        guard buffer.count + length <= FrameChunker.maxFrameSize else { throw FramingError.tooLarge }
        buffer.append(body.prefix(length))
        guard flags & FrameChunker.more == 0 else { return nil }
        let frame = isCompressed ? try Zlib.decompress(buffer, limit: FrameChunker.maxFrameSize) : buffer
        buffer = Data()
        compressed = nil
        return frame
    }
}

/// zlib de Apple (`COMPRESSION_ZLIB`, deflate crudo). Descomprime por partes con la salida acotada.
public enum Zlib {
    public static func compress(_ data: Data) throws -> Data {
        try process(data, operation: COMPRESSION_STREAM_ENCODE, limit: .max)
    }

    public static func decompress(_ data: Data, limit: Int) throws -> Data {
        try process(data, operation: COMPRESSION_STREAM_DECODE, limit: limit)
    }

    private static func process(_ input: Data, operation: compression_stream_operation, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw FramingError.malformed
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        // Una entrada vacía no tiene dirección base: el stream igual necesita un puntero válido.
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var output = Data()
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        let source = [UInt8](input)
        try source.withUnsafeBufferPointer { buffer in
            stream.pointee.src_ptr = buffer.baseAddress ?? UnsafePointer(placeholder)
            stream.pointee.src_size = buffer.count
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = capacity
                let pendingBefore = stream.pointee.src_size
                let status = compression_stream_process(stream, flags)
                let produced = capacity - stream.pointee.dst_size
                guard status != COMPRESSION_STATUS_ERROR else { throw FramingError.malformed }
                guard output.count + produced <= limit else { throw FramingError.tooLarge }
                output.append(destination, count: produced)
                if status == COMPRESSION_STATUS_END { return }
                // Sin avance (entrada truncada): no es un flujo válido.
                if produced == 0 && stream.pointee.src_size == pendingBefore { throw FramingError.malformed }
            }
        }
        return output
    }
}
