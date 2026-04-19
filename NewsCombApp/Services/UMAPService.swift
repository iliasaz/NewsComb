import Foundation
import OSLog

/// GPU-accelerated UMAP that delegates the heavy work to a sibling executable
/// (`newscomb-umap-bridge`) built from the local `umap-mlx-swift` package.
///
/// The bridge runs in a separate process so that MLX's symbols never enter the
/// main NewsCombApp module graph. SwiftAgents/Conduit (transitively pulled in
/// by HyperGraphReasoning) become uncompilable when MLX is visible to them but
/// not linked, because they gate `MLXProvider` references behind
/// `#if canImport(MLX)` without coordinating with Conduit's `MLX` package
/// trait. Isolating MLX behind a subprocess sidesteps that conflict and keeps
/// the SPM resolution graph of the main app unchanged.
///
/// The previous pure-Swift VP-tree + SGD layout was single-threaded on the CPU
/// and dominated the theme-rebuild pipeline at production scale (~tens of
/// minutes for ~116K events). The MLX-backed pipeline runs on Apple Silicon's
/// GPU/ANE.
final class UMAPService: Sendable {

    /// Configuration parameters for UMAP.
    ///
    /// Field names mirror the original CPU implementation so existing call
    /// sites and `AppSettings` keys keep working unchanged.
    struct Parameters {
        var targetDimension: Int = 25
        var nNeighbors: Int = 15
        var minDist: Float = 0.1
        /// `nil` lets the underlying MLX UMAP pick automatically
        /// (500 epochs if n<=10K, otherwise 200).
        var nEpochs: Int? = nil
        var negativeSampleRate: Int = 5
        var learningRate: Float = 1.0
        var spread: Float = 1.0
        /// `0` means "non-deterministic" to the bridge.
        var seed: UInt64 = 42
    }

    /// Errors thrown when the bridge subprocess can't be started or returns
    /// a malformed response.
    enum BridgeError: Error, LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case malformedResponse(String)
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "newscomb-umap-bridge executable not found alongside the app binary."
            case .launchFailed(let why):
                return "Failed to launch newscomb-umap-bridge: \(why)"
            case .malformedResponse(let why):
                return "newscomb-umap-bridge returned a malformed response: \(why)"
            case .nonZeroExit(let code, let stderr):
                return "newscomb-umap-bridge exited with code \(code): \(stderr)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.newscomb", category: "UMAPService")

    // MARK: - Public API

    /// Reduces vectors to a low-dimensional embedding via the GPU bridge.
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors (typically PCA-reduced to ~50D).
    ///   - params: UMAP configuration.
    ///   - progressCallback: Optional callback invoked with `(currentEpoch, totalEpochs)`
    ///     during SGD optimization. Forwarded from the bridge's stderr stream.
    /// - Returns: Array of N vectors, each of `params.targetDimension` dimensions.
    ///   Falls back to the input vectors on any bridge failure so the caller
    ///   pipeline can continue rather than crash.
    func reduce(
        vectors: [[Float]],
        params: Parameters = Parameters(),
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [[Float]] {
        let n = vectors.count
        guard n >= 2 else { return vectors }

        let inputDim = vectors[0].count
        // The bridge enforces dOut < dIn; short-circuit instead of erroring.
        guard params.targetDimension < inputDim else {
            logger.notice("UMAP: target dim (\(params.targetDimension)) >= input dim (\(inputDim)); returning input")
            return vectors
        }
        // Bridge requires nNeighbors < n; clamp to the largest valid value.
        let effectiveNeighbors = min(params.nNeighbors, n - 1)
        guard effectiveNeighbors >= 1 else { return vectors }

        logger.info("UMAP (bridge): n=\(n), inDim=\(inputDim), outDim=\(params.targetDimension), k=\(effectiveNeighbors)")
        let pipelineStart = ContinuousClock.now

        do {
            let result = try await Self.invokeBridge(
                vectors: vectors,
                n: n,
                dIn: inputDim,
                dOut: params.targetDimension,
                nNeighbors: effectiveNeighbors,
                params: params,
                progressCallback: progressCallback
            )
            let elapsed = ContinuousClock.now - pipelineStart
            logger.info("UMAP (bridge) complete: \(n) points → \(params.targetDimension)D in \(elapsed)")
            return result
        } catch {
            logger.error("UMAP (bridge) failed: \(error.localizedDescription) — returning input vectors")
            return vectors
        }
    }

    // MARK: - Bridge invocation

    /// Locates `newscomb-umap-bridge`. The build phase places it (and its
    /// colocated `mlx.metallib`) in `<App>.app/Contents/Helpers/` to avoid
    /// codesign collisions in `Contents/MacOS/`.
    private static func bridgeURL() -> URL? {
        let fm = FileManager.default
        let name = "newscomb-umap-bridge"

        // Inspect both the running process bundle and the bundle that
        // contains this class — the latter resolves to the host app when
        // running inside an xctest bundle.
        let candidates: [Bundle] = [.main, Bundle(for: BundleProbe.self)]
        for bundle in candidates {
            // Walk up from the bundle URL looking for an enclosing .app —
            // xctest bundles are nested inside the host app at
            // <App>.app/Contents/PlugIns/<Tests>.xctest, and we want the
            // outermost `.app` either way.
            var url = bundle.bundleURL
            for _ in 0..<5 {
                let helpers = url.appending(path: "Contents/Helpers").appending(path: name)
                if fm.fileExists(atPath: helpers.path) { return helpers }
                let mac = url.appending(path: "Contents/MacOS").appending(path: name)
                if fm.fileExists(atPath: mac.path) { return mac }
                url = url.deletingLastPathComponent()
            }
        }

        // Fallback: SPM-style auxiliary executable lookup.
        if let aux = Bundle.main.url(forAuxiliaryExecutable: name) {
            return aux
        }
        // Final fallback: same directory as the running executable.
        if let exec = Bundle.main.executableURL {
            let sibling = exec.deletingLastPathComponent().appending(path: name)
            if fm.fileExists(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    /// Marker class used solely to anchor `Bundle(for:)` so that
    /// test bundles can locate the host app bundle.
    private final class BundleProbe {}

    @concurrent
    private static func invokeBridge(
        vectors: [[Float]],
        n: Int,
        dIn: Int,
        dOut: Int,
        nNeighbors: Int,
        params: Parameters,
        progressCallback: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [[Float]] {
        guard let url = bridgeURL() else {
            throw BridgeError.binaryNotFound
        }

        let request = encodeRequest(
            vectors: vectors,
            n: n,
            dIn: dIn,
            dOut: dOut,
            nNeighbors: nNeighbors,
            params: params
        )

        let process = Process()
        process.executableURL = url
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BridgeError.launchFailed(String(describing: error))
        }

        // Stream progress lines off stderr without buffering the whole stream.
        let stderrTask = Task.detached(priority: .utility) {
            forwardProgress(handle: stderrPipe.fileHandleForReading, callback: progressCallback)
        }

        // Write the request payload, then close stdin so the child sees EOF.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: request)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw BridgeError.launchFailed("stdin write failed: \(error)")
        }

        // Drain stdout fully (binary response).
        let stdoutData: Data
        do {
            stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            process.terminate()
            throw BridgeError.malformedResponse("stdout read failed: \(error)")
        }

        process.waitUntilExit()
        let stderrTrailing = await stderrTask.value

        guard process.terminationStatus == 0 else {
            throw BridgeError.nonZeroExit(process.terminationStatus, stderrTrailing)
        }

        return try decodeResponse(stdoutData, expectedN: n, expectedDOut: dOut)
    }

    // MARK: - Wire format

    private static func encodeRequest(
        vectors: [[Float]],
        n: Int,
        dIn: Int,
        dOut: Int,
        nNeighbors: Int,
        params: Parameters
    ) -> Data {
        var data = Data()
        data.reserveCapacity(8 + 44 + n * dIn * MemoryLayout<Float>.size)
        data.append(contentsOf: Array("UMAPRQ01".utf8))

        var nVal = Int32(n)
        var dInVal = Int32(dIn)
        var dOutVal = Int32(dOut)
        var kVal = Int32(nNeighbors)
        var minDistVal = params.minDist
        var spreadVal = params.spread
        var nEpochsVal = Int32(params.nEpochs ?? 0)
        var negSampleVal = Int32(params.negativeSampleRate)
        var lrVal = params.learningRate
        var seedVal = params.seed

        withUnsafeBytes(of: &nVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dInVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dOutVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &kVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &minDistVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &spreadVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &nEpochsVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &negSampleVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lrVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &seedVal) { data.append(contentsOf: $0) }

        // Flatten input rows into a contiguous Float32 buffer (single copy).
        var flat = [Float](repeating: 0, count: n * dIn)
        flat.withUnsafeMutableBufferPointer { dst in
            for i in 0..<n {
                let row = vectors[i]
                let count = Swift.min(row.count, dIn)
                row.withUnsafeBufferPointer { src in
                    for j in 0..<count {
                        dst[i * dIn + j] = src[j]
                    }
                }
            }
        }
        flat.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: buf.count * MemoryLayout<Float>.size)
            data.append(contentsOf: raw)
        }

        return data
    }

    private static func decodeResponse(_ data: Data, expectedN: Int, expectedDOut: Int) throws -> [[Float]] {
        let headerLen = 8 + 4 + 4
        guard data.count >= headerLen else {
            throw BridgeError.malformedResponse("response too short: \(data.count) bytes")
        }
        let magic = data.prefix(8)
        guard magic == Data("UMAPRS01".utf8) else {
            let preview = String(data: magic, encoding: .utf8) ?? magic.map { String(format: "%02x", $0) }.joined()
            throw BridgeError.malformedResponse("bad magic: \(preview)")
        }
        let n: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
        let d: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
        guard Int(n) == expectedN, Int(d) == expectedDOut else {
            throw BridgeError.malformedResponse("shape mismatch: got \(n)x\(d), expected \(expectedN)x\(expectedDOut)")
        }
        let payloadCount = Int(n) * Int(d)
        let payloadBytes = payloadCount * MemoryLayout<Float>.size
        guard data.count == headerLen + payloadBytes else {
            throw BridgeError.malformedResponse("payload length mismatch: got \(data.count - headerLen) bytes, expected \(payloadBytes)")
        }

        let floats: [Float] = data.withUnsafeBytes { rawBuf -> [Float] in
            let typed = rawBuf.baseAddress!.advanced(by: headerLen).bindMemory(to: Float.self, capacity: payloadCount)
            return Array(UnsafeBufferPointer(start: typed, count: payloadCount))
        }

        var result: [[Float]] = []
        result.reserveCapacity(Int(n))
        let stride = Int(d)
        for i in 0..<Int(n) {
            let start = i * stride
            result.append(Array(floats[start..<(start + stride)]))
        }
        return result
    }

    // MARK: - Stderr progress forwarding

    /// Reads `PROGRESS\t<epoch>\t<total>` lines off the bridge's stderr and
    /// forwards them to the caller. Returns whatever non-progress text was
    /// produced (typically a final ERROR line) so it can be surfaced on
    /// non-zero exit.
    private static func forwardProgress(
        handle: FileHandle,
        callback: (@Sendable (Int, Int) -> Void)?
    ) -> String {
        var trailing = ""
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nlIdx = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<nlIdx)
                pending.removeSubrange(pending.startIndex...nlIdx)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if line.hasPrefix("PROGRESS\t") {
                    let parts = line.split(separator: "\t")
                    if parts.count == 3, let epoch = Int(parts[1]), let total = Int(parts[2]) {
                        callback?(epoch, total)
                    }
                } else {
                    trailing += line + "\n"
                }
            }
        }
        if !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) {
            trailing += tail
        }
        return trailing
    }
}
