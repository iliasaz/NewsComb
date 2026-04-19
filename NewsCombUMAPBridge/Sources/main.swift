// newscomb-umap-bridge: GPU-accelerated UMAP via MLX as a subprocess.
//
// Wire protocol (binary, host-endian on Apple Silicon = little-endian):
//
// Request on stdin:
//   8  bytes  magic "UMAPRQ01"
//   4  Int32  n            -- number of input vectors
//   4  Int32  dIn          -- input dimension
//   4  Int32  dOut         -- target dimension
//   4  Int32  nNeighbors
//   4  Float  minDist
//   4  Float  spread
//   4  Int32  nEpochs       -- 0 means "auto" (let MLX UMAP pick)
//   4  Int32  negativeSampleRate
//   4  Float  learningRate
//   8  UInt64 seed          -- 0 means "no seed" (MLXRandom non-deterministic)
//   n * dIn * 4 bytes Float32 row-major vectors
//
// Response on stdout:
//   8  bytes  magic "UMAPRS01"
//   4  Int32  n
//   4  Int32  dOut
//   n * dOut * 4 bytes Float32 row-major vectors
//
// Progress (optional, on stderr, line-oriented):
//   "PROGRESS\t<epoch>\t<total>\n"
//
// Errors are reported via non-zero exit code with a final stderr line:
//   "ERROR\t<message>\n"

import Foundation
import MLX
import UMAPMLX

private func readPOSIX(_ fd: Int32, _ count: Int) -> Data? {
    var buf = Data(count: count)
    var read = 0
    while read < count {
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress?.advanced(by: read) else { return -1 }
            return Darwin.read(fd, base, count - read)
        }
        if n <= 0 { return nil }
        read += n
    }
    return buf
}

private func writePOSIX(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        var written = 0
        while written < data.count {
            let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
            if n <= 0 { break }
            written += n
        }
    }
}

private func bail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR\t\(message)\n".utf8))
    exit(2)
}

// MARK: - Read request

let inFD = FileHandle.standardInput.fileDescriptor
let outFD = FileHandle.standardOutput.fileDescriptor

guard let header = readPOSIX(inFD, 8), header == Data("UMAPRQ01".utf8) else {
    bail("bad request magic")
}

func readInt32() -> Int32 {
    guard let d = readPOSIX(inFD, 4) else { bail("short read on Int32") }
    return d.withUnsafeBytes { $0.load(as: Int32.self) }
}

func readFloat() -> Float {
    guard let d = readPOSIX(inFD, 4) else { bail("short read on Float") }
    return d.withUnsafeBytes { $0.load(as: Float.self) }
}

func readUInt64() -> UInt64 {
    guard let d = readPOSIX(inFD, 8) else { bail("short read on UInt64") }
    return d.withUnsafeBytes { $0.load(as: UInt64.self) }
}

let n = Int(readInt32())
let dIn = Int(readInt32())
let dOut = Int(readInt32())
let nNeighbors = Int(readInt32())
let minDist = readFloat()
let spread = readFloat()
let nEpochsRaw = Int(readInt32())
let negativeSampleRate = Int(readInt32())
let learningRate = readFloat()
let seedRaw = readUInt64()

guard n > 0, dIn > 0, dOut > 0, dOut <= dIn else {
    bail("invalid dimensions: n=\(n) dIn=\(dIn) dOut=\(dOut)")
}
guard nNeighbors > 0, nNeighbors < n else {
    bail("nNeighbors=\(nNeighbors) must be in 1..<n=\(n)")
}

let payloadBytes = n * dIn * MemoryLayout<Float>.size
guard let payload = readPOSIX(inFD, payloadBytes) else {
    bail("short read on payload (\(payloadBytes) bytes)")
}

FileHandle.standardError.write(
    Data("UMAP-Bridge: n=\(n) dIn=\(dIn) dOut=\(dOut) k=\(nNeighbors) epochs=\(nEpochsRaw)\n".utf8)
)

// MARK: - Build MLXArray and run UMAP

let inputArray: MLXArray = payload.withUnsafeBytes { rawBuf -> MLXArray in
    let floats = rawBuf.bindMemory(to: Float.self)
    let array = Array(UnsafeBufferPointer(start: floats.baseAddress, count: n * dIn))
    return MLXArray(array, [n, dIn])
}

var configuration = UMAP.Configuration()
configuration.nComponents = dOut
configuration.nNeighbors = nNeighbors
configuration.minDist = minDist
configuration.spread = spread
configuration.nEpochs = nEpochsRaw == 0 ? nil : nEpochsRaw
configuration.negativeSampleRate = negativeSampleRate
configuration.learningRate = learningRate
configuration.randomSeed = seedRaw == 0 ? nil : seedRaw

let umap = UMAP(configuration)

let progressCallback: @Sendable (Int, Int) -> Void = { epoch, total in
    FileHandle.standardError.write(Data("PROGRESS\t\(epoch)\t\(total)\n".utf8))
}

let embedding: MLXArray
do {
    embedding = try umap.fitTransform(inputArray, progressCallback: progressCallback)
    eval(embedding)
} catch {
    bail("UMAP failed: \(String(describing: error))")
}

// MARK: - Write response

let resultFloats = embedding.asArray(Float.self)
guard resultFloats.count == n * dOut else {
    bail("embedding shape mismatch: got \(resultFloats.count), expected \(n * dOut)")
}

writePOSIX(outFD, Data("UMAPRS01".utf8))

var nOut = Int32(n)
var dOutOut = Int32(dOut)
writePOSIX(outFD, Data(bytes: &nOut, count: 4))
writePOSIX(outFD, Data(bytes: &dOutOut, count: 4))

resultFloats.withUnsafeBufferPointer { buf in
    guard let base = buf.baseAddress else { return }
    let data = Data(bytes: base, count: buf.count * MemoryLayout<Float>.size)
    writePOSIX(outFD, data)
}

FileHandle.standardError.write(Data("UMAP-Bridge: done\n".utf8))
