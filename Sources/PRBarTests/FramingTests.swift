import Foundation
import PRBarRemoteKit

enum FramingTests {
    static func roundTrip(_ data: Data, compress: Bool = false) throws -> [Data] {
        let chunks = try FrameChunker.chunks(for: data, compress: compress)
        var assembler = FrameAssembler()
        var result: Data?
        for (index, chunk) in chunks.enumerated() {
            try expect(chunk.count % 256 == 0 && chunk.count <= 65_280 && chunk.count >= 256, "trozo de \(chunk.count)")
            let out = try assembler.add(chunk)
            try expect((out == nil) == (index < chunks.count - 1), "terminó en el trozo \(index)")
            result = out
        }
        try expect(result == data, "no rearmó igual (\(data.count) bytes)")
        return chunks
    }

    static func assemble(_ chunks: [Data]) throws -> Data? {
        var assembler = FrameAssembler()
        var out: Data?
        for chunk in chunks { out = try assembler.add(chunk) }
        return out
    }

    static let cases: [TestCase] = [
        TestCase("framing: trozos de múltiplo de 256 que rearman igual") {
            try expectEqual(try roundTrip(Data()).count, 1)
            try expectEqual(try roundTrip(Data([42])).count, 1)
            try expectEqual(try roundTrip(Data(repeating: 1, count: 65_277)).count, 1)
            try expectEqual(try roundTrip(Data(repeating: 1, count: 65_278)).count, 2)
            _ = try roundTrip(randomBytes(1 << 20))
            _ = try roundTrip(Data(repeating: 3, count: 16 << 20))
        },
        TestCase("framing: más de 16 MiB se rechaza al armar y al rearmar") {
            do {
                _ = try FrameChunker.chunks(for: Data(count: (16 << 20) + 1), compress: false)
                throw TestFailure(description: "armó 16 MiB + 1")
            } catch let error as FramingError {
                try expectEqual(error, .tooLarge)
            }
            // Un emisor malicioso: trozos "siguen más" sin fin. Falla en cuanto pasa el tope.
            var more = Data([1]) + Data(uint16BE: 65_277) + Data(repeating: 0, count: 65_277)
            more = more.prefix(65_280)
            var assembler = FrameAssembler()
            var failedAt: Int?
            for index in 0..<300 {
                do {
                    _ = try assembler.add(more)
                } catch let error as FramingError {
                    try expectEqual(error, .tooLarge)
                    failedAt = index
                    break
                }
            }
            try expectEqual(failedAt, 257)   // 257 × 65 277 > 16 MiB
        },
        TestCase("framing: compresión con menos trozos, bit en todos y rearmado igual") {
            let row = #"{"id":"acme/web#1","title":"Fix the thing","ci":"passed","author":"ana"},"#
            let json = Data(String(repeating: row, count: (1 << 20) / row.utf8.count).utf8)
            let plain = try FrameChunker.chunks(for: json, compress: false)
            let compressed = try roundTrip(json, compress: true)
            try expect(compressed.count < plain.count)
            try expect(compressed.allSatisfy { $0[$0.startIndex] & 0b10 != 0 })
            _ = try roundTrip(Data(), compress: true)
            _ = try roundTrip(randomBytes(200_000), compress: true)
        },
        TestCase("framing: trozos malformados") {
            let good = try FrameChunker.chunks(for: Data("hola".utf8), compress: false)[0]
            var longLen = good
            longLen.replaceSubrange(longLen.startIndex + 1..<longLen.startIndex + 3, with: Data(uint16BE: 254))
            try expect((try? assemble([longLen])) == nil)                    // len mayor que lo que queda
            var dirty = good
            dirty[dirty.startIndex + 200] = 1
            try expect((try? assemble([dirty])) == nil)                      // relleno no cero
            try expect((try? assemble([good.prefix(255)])) == nil)           // no es múltiplo de 256
            var flags = good
            flags[flags.startIndex] = 0b100
            try expect((try? assemble([flags])) == nil)                      // bits desconocidos
            // Mezclar comprimido y sin comprimir en un marco.
            var first = try FrameChunker.chunks(for: Data(repeating: 1, count: 70_000), compress: false)
            first[1][first[1].startIndex] |= 0b10
            try expect((try? assemble(first)) == nil)
            // Datos "comprimidos" que no son zlib.
            var fake = good
            fake[fake.startIndex] = 0b10
            try expect((try? assemble([fake])) == nil)
        },
        TestCase("framing: una bomba de compresión no pasa de 16 MiB") {
            let bomb = try FrameChunker.chunks(for: Data(count: 16 << 20), compress: true)
            try expect(bomb.count < 5)
            try expectEqual(try assemble(bomb)?.count, 16 << 20)
            // 17 MiB de ceros comprimidos por fuera del chunker: el ensamblador corta en 16 MiB.
            let compressed = try Zlib.compress(Data(count: 17 << 20))
            var chunks: [Data] = []
            var rest = compressed[...]
            repeat {
                let piece = rest.prefix(65_277)
                rest = rest.dropFirst(piece.count)
                var chunk = Data([0b10 | (rest.isEmpty ? 0 : 1)]) + Data(uint16BE: UInt16(piece.count)) + piece
                chunk.append(Data(count: (256 - chunk.count % 256) % 256))
                chunks.append(chunk)
            } while !rest.isEmpty
            do {
                _ = try assemble(chunks)
                throw TestFailure(description: "infló más de 16 MiB")
            } catch let error as FramingError {
                try expectEqual(error, .tooLarge)
            }
        },
    ]
}
