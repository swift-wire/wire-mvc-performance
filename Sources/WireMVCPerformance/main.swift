import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

// The driver. Each scenario is started on an ephemeral port, driven with the **same** `AsyncHTTPClient`
// over a real socket, and timed — so the socket, the client and the request shape are constants and a
// difference between scenarios is server-side.
//
// Driving over a socket rather than through each framework's in-process test client is the whole reason
// this package exists. An earlier measurement compared `HummingbirdTesting`'s router mode against
// `WireMVCTesting`'s in-process client and could not tell a several-microsecond difference in the servers
// from a difference in the harnesses.

let warmup = ProcessInfo.processInfo.environment["WARMUP"].flatMap(Int.init) ?? 2_000
let iterations = ProcessInfo.processInfo.environment["ITERATIONS"].flatMap(Int.init) ?? 20_000
let rounds = ProcessInfo.processInfo.environment["ROUNDS"].flatMap(Int.init) ?? 3

let all: [any Scenario] = [
    HummingbirdRaw(), HummingbirdPlain(), HummingbirdBridged(),
    VaporRaw(), VaporPlain(), VaporBridged(),
    ProposalPlain(), ProposalPlainServed(), ProposalNative(),
]
// `SCENARIOS=proposal-plain,proposal-native` runs a subset — for isolating one stack while iterating.
let selected = ProcessInfo.processInfo.environment["SCENARIOS"]?.split(separator: ",").map(String.init)
let scenarios = selected.map { names in all.filter { names.contains($0.name) } } ?? all

struct Measurement {
    let scenario: String
    let detail: String
    /// Every request's latency, in microseconds — not per-round means.
    ///
    /// Round means hide the distribution, which is the interesting part: two paths can share a median and
    /// differ entirely in their tail, and a mean cannot say so. Allocation-driven costs in particular show
    /// up as a tail rather than as a shifted centre.
    var samples: [Double] = []

    var sorted: [Double] { samples.sorted() }
    func percentile(_ value: Double) -> Double {
        let ordered = sorted
        guard !ordered.isEmpty else { return 0 }
        let index = Int((value / 100) * Double(ordered.count - 1))
        return ordered[max(0, min(ordered.count - 1, index))]
    }
    var minimum: Double { samples.min() ?? 0 }
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
}

/// Drive one scenario: start it, wait for its port, hit it, then cancel.
///
/// The client is passed in rather than created here: one client for the whole run means connection setup
/// is warmed once and is not itself part of what varies between scenarios.
func measure(_ scenario: any Scenario, client: HTTPClient) async throws -> Measurement {
    var measurement = Measurement(scenario: scenario.name, detail: scenario.detail)
    let port = AsyncStream<Int>.makeStream()

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            // Errors are swallowed on purpose: this task is cancelled once the measurement is done, and
            // both servers surface that as a thrown error ("I/O on closed channel", `CancellationError`)
            // which would otherwise propagate out of the group and end the run.
            try? await scenario.run { port.continuation.yield($0) }
        }

        var iterator = port.stream.makeAsyncIterator()
        guard let boundPort = await iterator.next() else { throw HarnessError.serverNeverBound }

        let url = "http://127.0.0.1:\(boundPort)/echo/benchmark"
        /// Drive `count` requests, returning each one's latency in microseconds when `record` is set.
        @discardableResult
        func hit(_ count: Int, record: Bool = false) async throws -> [Double] {
            var samples: [Double] = []
            if record { samples.reserveCapacity(count) }
            for _ in 0..<count {
                var request = HTTPClientRequest(url: url)
                request.headers.add(name: "connection", value: "keep-alive")
                let start = ContinuousClock.now
                let response = try await client.execute(request, timeout: .seconds(10))
                guard response.status == .ok else {
                    throw HarnessError.unexpectedStatus(Int(response.status.code))
                }
                _ = try await response.body.collect(upTo: 1024)
                if record { samples.append(micros(since: start)) }
            }
            return samples
        }

        try await hit(warmup)
        for _ in 0..<rounds {
            measurement.samples.append(contentsOf: try await hit(iterations, record: true))
        }

        group.cancelAll()
    }
    return measurement
}

/// Microseconds elapsed since `start`.
func micros(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1_000_000
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000
}

enum HarnessError: Error {
    case serverNeverBound
    case unexpectedStatus(Int)
}

// `PROBE=1` — start each selected scenario and print the response headers it actually puts on the wire.
//
// Framing is invisible to a latency number but changes the bytes and the client-side decode: a response
// with `Content-Length` is written once and read once, a response without one is chunked, which adds a
// size line, a terminator and a decoder. Two scenarios can be identical in every layer the in-process
// bisection covers and still differ here, because the in-process sender discards without framing anything.
if ProcessInfo.processInfo.environment["PROBE"] != nil {
    print("wire framing per scenario")
    for scenario in scenarios {
        let port = AsyncStream<Int>.makeStream()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try? await scenario.run { port.continuation.yield($0) } }
            var iterator = port.stream.makeAsyncIterator()
            guard let boundPort = await iterator.next() else { throw HarnessError.serverNeverBound }

            // `curl -v` rather than a hand-rolled socket: the response headers are printed verbatim,
            // including the framing header, and curl is not doing anything the driving client would not.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "-sv", "-o", "/dev/null", "--http1.1",
                "http://127.0.0.1:\(boundPort)/echo/benchmark",
            ]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let headers = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.hasPrefix("< ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("")
            print(scenario.name)
            for header in headers where !header.isEmpty { print("  " + header) }
            group.cancelAll()
        }
    }
    exit(0)
}

// The in-process pass: no socket, no HTTP client, no kernel. A tail that survives here is the router's.
if ProcessInfo.processInfo.environment["SKIP_INPROCESS"] == nil {
    print("")
    print("in process — no socket, no HTTP client")
    print("case                      min      p50      p90      p99      max     mean")
    var previous: Measurement?
    // `INPROCESS=trie-only` runs one case — for counting allocations, where only differences mean
    // anything and a single case per process is what makes the subtraction clean.
    let wanted = ProcessInfo.processInfo.environment["INPROCESS"]?.split(separator: ",").map(String.init)
    let cases = wanted.map { names in inProcessCases.filter { names.contains($0.name) } } ?? inProcessCases
    for subject in cases {
        var measurement = Measurement(scenario: subject.name, detail: subject.detail)
        for _ in 0..<rounds {
            measurement.samples.append(
                contentsOf: try await driveInProcess(subject, warmup: warmup, iterations: iterations)
            )
        }
        let name = subject.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        let columns = [
            measurement.minimum, measurement.percentile(50), measurement.percentile(90),
            measurement.percentile(99), measurement.percentile(100), measurement.mean,
        ]
        print(name + columns.map { String(format: "%8.2f", $0) }.joined(separator: " "))
        if let previous {
            let label = previous.scenario.padding(toLength: 18, withPad: " ", startingAt: 0)
            print(
                String(
                    format: "  vs %@ p50 %+7.3f   p99 %+8.3f µs",
                    label,
                    measurement.percentile(50) - previous.percentile(50),
                    measurement.percentile(99) - previous.percentile(99)
                )
            )
        }
        previous = measurement
    }

    // The courier, which the cases above skip. Compared against `trie-only`, whose route body it repeats.
    if wanted == nil || wanted?.contains("courier") == true {
        var measurement = Measurement(scenario: "+courier", detail: "WireMVCContextHandler over the router")
        for _ in 0..<rounds {
            measurement.samples.append(
                contentsOf: try await driveCourier(warmup: warmup, iterations: iterations)
            )
        }
        let columns = [
            measurement.minimum, measurement.percentile(50), measurement.percentile(90),
            measurement.percentile(99), measurement.percentile(100), measurement.mean,
        ]
        print(
            "+courier".padding(toLength: 22, withPad: " ", startingAt: 0)
                + columns.map { String(format: "%8.2f", $0) }.joined(separator: " ")
        )
    }
}

// HTTP/1.1 only and an explicit pool: the defaults negotiate, and a benchmark wants the transport pinned
// so every scenario is driven identically.
var configuration = HTTPClient.Configuration()
configuration.httpVersion = .http1Only
let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
/// Drive every scenario **round-robin** from one loop, with all their servers already running.
///
/// Sequential measurement gives each scenario its own slice of wall-clock, so anything drifting on the
/// machine — thermal state, another process, the page cache — lands on whichever scenario was running at
/// the time and is then reported as that scenario's cost. Interleaving draws every scenario's samples from
/// the same windows, so drift hits them all and cancels in the comparison.
///
/// This is what the earlier "+20 µs at p99 for WireMVC" turned out to be, and the in-process pass is what
/// exposed it. `SEQUENTIAL=1` runs the old way, for reproducing the artefact rather than avoiding it.
func measureInterleaved(_ scenarios: [any Scenario], client: HTTPClient) async throws -> [Measurement] {
    var measurements = scenarios.map { Measurement(scenario: $0.name, detail: $0.detail) }

    return try await withThrowingTaskGroup(of: Void.self) { group in
        var urls: [String] = []
        for scenario in scenarios {
            let port = AsyncStream<Int>.makeStream()
            group.addTask { try? await scenario.run { port.continuation.yield($0) } }
            var iterator = port.stream.makeAsyncIterator()
            guard let bound = await iterator.next() else { throw HarnessError.serverNeverBound }
            urls.append("http://127.0.0.1:\(bound)/echo/benchmark")
        }

        func hit(_ url: String) async throws -> Double {
            var request = HTTPClientRequest(url: url)
            request.headers.add(name: "connection", value: "keep-alive")
            let start = ContinuousClock.now
            let response = try await client.execute(request, timeout: .seconds(10))
            guard response.status == .ok else {
                throw HarnessError.unexpectedStatus(Int(response.status.code))
            }
            _ = try await response.body.collect(upTo: 1024)
            return micros(since: start)
        }

        for _ in 0..<warmup {
            for url in urls { _ = try await hit(url) }
        }
        for _ in 0..<(iterations * rounds) {
            // One pass of the ring per iteration, so consecutive samples of different scenarios are
            // microseconds apart rather than minutes.
            for (index, url) in urls.enumerated() {
                measurements[index].samples.append(try await hit(url))
            }
        }

        group.cancelAll()
        return measurements
    }
}

var results: [Measurement] = []
if ProcessInfo.processInfo.environment["SEQUENTIAL"] != nil {
    for scenario in scenarios {
        FileHandle.standardError.write(Data("→ \(scenario.name)\n".utf8))
        do {
            results.append(try await measure(scenario, client: client))
        } catch {
            FileHandle.standardError.write(Data("  FAILED: \(error)\n".utf8))
        }
    }
} else if !scenarios.isEmpty {
    results = try await measureInterleaved(scenarios, client: client)
}
try await client.shutdown()

// Report the distribution. The minimum is the cleanest estimate of the cost itself — noise is one-sided,
// so nothing makes a request artificially fast — and the tail is where work that is *usually* cheap but
// occasionally not, such as an allocation that triggers a growth, shows itself.
print("")
let order = ProcessInfo.processInfo.environment["SEQUENTIAL"] != nil ? "sequential" : "interleaved"
print("iterations: \(iterations) per round, \(rounds) rounds, \(warmup) warmup, \(order)")
print("")
print("scenario                  min      p50      p90      p99      max     mean")
for result in results {
    let name = result.scenario.padding(toLength: 22, withPad: " ", startingAt: 0)
    let columns = [
        result.minimum, result.percentile(50), result.percentile(90), result.percentile(99),
        result.percentile(100), result.mean,
    ]
    print(name + columns.map { String(format: "%8.2f", $0) }.joined(separator: " "))
}

let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.scenario, $0) })

// Each delta compares a server to *itself* plus something, so the HTTP server cancels out. Comparing
// across frameworks would not isolate anything: the bare servers differ before WireMVC is involved.
print("")
print("isolated costs (each against its own bare server)")
for (label, with, without) in [
    ("WireMVC alone, proposal path ", "proposal-native", "proposal-plain"),
    ("WireMVC + bridge, Hummingbird", "hummingbird-bridged", "hummingbird-plain"),
    ("WireMVC + bridge, Vapor      ", "vapor-bridged", "vapor-plain"),
] {
    guard let a = byName[with], let b = byName[without] else { continue }
    // Reported at three points, because a difference that only appears in the tail is a different claim
    // from one that shifts the whole distribution.
    print(
        String(
            format: "  %@ min %+7.2f   p50 %+7.2f   p99 %+8.2f µs",
            label,
            a.minimum - b.minimum,
            a.percentile(50) - b.percentile(50),
            a.percentile(99) - b.percentile(99)
        )
    )
}

print("")
print("what each router costs (routed − routerless, same framework)")
for (label, routed, raw) in [
    ("Hummingbird's own router     ", "hummingbird-plain", "hummingbird-raw"),
    ("Vapor's own router           ", "vapor-plain", "vapor-raw"),
    ("WireMVC.serve vs server.serve", "proposal-plain-served", "proposal-plain"),
    ("WireMVC's handler, same serve", "proposal-native", "proposal-plain-served"),
] {
    guard let a = byName[routed], let b = byName[raw] else { continue }
    print(
        String(
            format: "  %@ min %+7.2f   p50 %+7.2f   p99 %+8.2f µs",
            label,
            a.minimum - b.minimum,
            a.percentile(50) - b.percentile(50),
            a.percentile(99) - b.percentile(99)
        )
    )
}

print("")
print("routerless floors, for reference (the servers themselves)")
for name in ["hummingbird-raw", "vapor-raw", "proposal-plain"] {
    guard let value = byName[name] else { continue }
    let padded = name.padding(toLength: 20, withPad: " ", startingAt: 0)
    print(String(format: "  %@ p50 %8.2f µs", padded, value.percentile(50)))
}
