import Darwin
import Foundation
import XCTest

@testable import Obsidian

/// The mandatory suite runs every benchmark for correctness (result counts
/// and non-empty results), checks that cancelled searches finish with an empty
/// result, bounds memory growth with a generous ceiling, and prints timings and
/// memory use. Absolute wall-clock thresholds, the strict peak-footprint limit
/// and the cancellation-latency limit depend on the machine and its load, so
/// they are only enforced by the standalone full profile
/// (`scripts/benchmark_search.sh --full`, which compiles with
/// `MARKDOWN_SEARCH_BENCHMARK_FULL`).
final class SearchBenchmarkTests: XCTestCase {
    func testAdvancedFiltersAcrossTwoThousandNotes() {
        let noteCount = 2_000
        let entries = Self.makeAdvancedEntries(count: noteCount)

        for (label, query, expectedCount) in [
            ("file", "file:\"Note 00073\"", 1),
            ("task", "task:open", noteCount / 2),
            ("metadata", "tag:swift property:status=active", noteCount / 2)
        ] {
            var samples: [Double] = []
            // Each call starts with the maintained index snapshot, as opening
            // a new palette does. Only the shared note bodies retain caches.
            for _ in 0..<4 {
                let started = DispatchTime.now().uptimeNanoseconds
                let results = ObsidianAdvancedSearchEvaluator.search(entries, query: query)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                XCTAssertEqual(results.count, expectedCount)
            }
            let repeatedSamples = Array(samples.dropFirst()).sorted()
            print(String(
                format: "ADVANCED_SEARCH_BENCHMARK filter=%@ notes=%d first_ms=%.2f reopen_p50_ms=%.2f reopen_p95_ms=%.2f",
                label,
                noteCount,
                samples[0],
                Self.percentile(0.50, in: repeatedSamples),
                Self.percentile(0.95, in: repeatedSamples)
            ))
#if MARKDOWN_SEARCH_BENCHMARK_FULL
            XCTAssertLessThanOrEqual(
                Self.percentile(0.95, in: repeatedSamples),
                150,
                "Reopening \(label) searches should avoid reparsing the 2,000-note corpus"
            )
#endif
        }
    }

    /// A cancelled search must stop early and return an empty result. Each
    /// search runs in a task that is already cancelled, so the outcome does
    /// not depend on timing. It covers the sequential and parallel plain-text
    /// scans and the advanced-filter evaluator loop.
    func testCancelledSearchesReturnEmptyResults() async {
        let sequentialEntries = Self.makeEntries(count: 100)
        let parallelEntries = Self.makeEntries(count: 4_000)
        let advancedEntries = Self.makeAdvancedEntries(count: 400)

        XCTAssertFalse(Workspace.search(sequentialEntries, query: "benchmark-target").isEmpty)
        XCTAssertFalse(Workspace.search(parallelEntries, query: "benchmark-target").isEmpty)
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(advancedEntries, query: "task:open").count, 200)

        let sequential = await Self.runInCancelledTask {
            Workspace.search(sequentialEntries, query: "benchmark-target")
        }
        let parallel = await Self.runInCancelledTask {
            Workspace.search(parallelEntries, query: "benchmark-target")
        }
        let advanced = await Self.runInCancelledTask {
            ObsidianAdvancedSearchEvaluator.search(advancedEntries, query: "task:open")
        }

        XCTAssertTrue(sequential.isEmpty, "A cancelled sequential scan should return no results")
        XCTAssertTrue(parallel.isEmpty, "A cancelled parallel scan should return no results")
        XCTAssertTrue(advanced.isEmpty, "A cancelled advanced search should return no results")
    }

    /// Runs `work` in a detached task that observes its own cancellation
    /// before starting, so `work` always executes in a cancelled task.
    private static func runInCancelledTask<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result
    ) async -> Result {
        let task = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            return work()
        }
        task.cancel()
        return await task.value
    }

    private static func makeAdvancedEntries(count noteCount: Int) -> [NoteSearchEntry] {
        let filler = String(repeating: "Reference material and project planning details.\n", count: 20)
        return (0..<noteCount).map { index in
            let title = String(format: "Note %05d", index)
            let isActive = index.isMultiple(of: 2)
            let body = "---\ntags: [swift]\nstatus: \(isActive ? "active" : "archived")\n---\n"
                + "# \(title)\n\n" + filler
                + (isActive ? "- [ ] Ship the release\n" : "- [x] Archive the release\n")
            let url = URL(fileURLWithPath: "/benchmark/work/\(title).md")
            return NoteSearchEntry(
                id: url,
                url: url,
                title: title,
                relativePath: "work/\(title).md",
                body: body,
                foldedTitle: Workspace.foldedForSearch(title),
                foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(title).md")
            )
        }
    }

    func testDeterministicTenAndFiftyThousandNoteThresholds() async throws {
#if MARKDOWN_SEARCH_BENCHMARK_FULL
        let iterations = 12
#else
        // The mandatory suite always runs the real 10k/50k corpora for
        // correctness. The standalone --full profile expands the
        // distribution to 12 samples and enforces the thresholds.
        let iterations = 3
#endif
        try await benchmark(noteCount: 10_000, iterations: iterations, p95LimitMilliseconds: 500)
        try await benchmark(noteCount: 50_000, iterations: iterations, p95LimitMilliseconds: 2_000)
    }

    private func benchmark(
        noteCount: Int,
        iterations: Int,
        p95LimitMilliseconds: Double
    ) async throws {
        let baselineFootprint = Self.physicalFootprint()
        let entries = Self.makeEntries(count: noteCount)

        // Warm caches before collecting a distribution.
        _ = Workspace.search(entries, query: "benchmark-target")

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for iteration in 0..<iterations {
            let query = iteration.isMultiple(of: 2) ? "benchmark-target" : "shard-73"
            let started = DispatchTime.now().uptimeNanoseconds
            let results = Workspace.search(entries, query: query)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            XCTAssertFalse(results.isEmpty)
            samples.append(Double(elapsed) / 1_000_000)
        }

        let sorted = samples.sorted()
        let p50 = Self.percentile(0.50, in: sorted)
        let p95 = Self.percentile(0.95, in: sorted)

        let cancellationWorker = Task.detached(priority: .userInitiated) {
            Workspace.search(entries, query: "definitely-absent-cancellation-query")
        }
        try await Task.sleep(for: .milliseconds(1))
        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        cancellationWorker.cancel()
        _ = await cancellationWorker.value
        let cancellationMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStarted
        ) / 1_000_000

        // Measured while the corpus and its caches are still alive, so the
        // current delta is the memory this search workload holds on to. The
        // peak catches a temporary spike that was already released.
        let footprint = Self.physicalFootprint()
        let footprintDeltaBytes = footprint.current >= baselineFootprint.current
            ? footprint.current - baselineFootprint.current
            : 0
        let peakGrowthBytes = footprint.peak >= baselineFootprint.current
            ? footprint.peak - baselineFootprint.current
            : 0

        print(
            String(
                format: "SEARCH_BENCHMARK notes=%d iterations=%d p50_ms=%.2f p95_ms=%.2f footprint_mb=%.1f footprint_delta_mb=%.1f footprint_peak_growth_mb=%.1f cancellation_ms=%.2f",
                noteCount,
                iterations,
                p50,
                p95,
                Double(footprint.current) / 1_048_576,
                Double(footprintDeltaBytes) / 1_048_576,
                Double(peakGrowthBytes) / 1_048_576,
                cancellationMilliseconds
            )
        )

        // Generous enough for any machine: a 50,000-note corpus is far below
        // this, so only a gross leak or runaway cache trips it.
        XCTAssertLessThanOrEqual(
            footprintDeltaBytes,
            4 * 1_024 * 1_024 * 1_024,
            "\(noteCount)-note search grew the physical footprint by more than 4 GiB"
        )

#if MARKDOWN_SEARCH_BENCHMARK_FULL
        XCTAssertLessThanOrEqual(
            p95,
            p95LimitMilliseconds,
            "\(noteCount)-note p95 exceeded the maintained threshold"
        )
        XCTAssertLessThanOrEqual(
            peakGrowthBytes,
            1_024 * 1_024 * 1_024,
            "\(noteCount)-note search peaked more than 1 GiB above the starting physical footprint"
        )
        XCTAssertLessThanOrEqual(
            cancellationMilliseconds,
            200,
            "Cancellation should be observed within 200 ms"
        )
#endif
    }

    private static func makeEntries(count: Int) -> [NoteSearchEntry] {
        let filler = String(repeating: "alpha beta gamma delta interface craft ", count: 6)
        return (0..<count).map { index in
            let title = String(format: "Note %05d", index)
            let body = "# \(title)\n\n\(filler)shard-\(index % 101) "
                + (index.isMultiple(of: 997) ? "benchmark-target" : "ordinary-content")
            let url = URL(fileURLWithPath: "/benchmark/\(title).md")
            return NoteSearchEntry(
                id: url,
                url: url,
                title: title,
                relativePath: "benchmark/\(title).md",
                body: body,
                foldedTitle: Workspace.foldedForSearch(title),
                foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(title).md")
            )
        }
    }

    private static func percentile(_ percentile: Double, in sortedSamples: [Double]) -> Double {
        guard !sortedSamples.isEmpty else { return 0 }
        let index = max(0, min(sortedSamples.count - 1, Int(ceil(percentile * Double(sortedSamples.count))) - 1))
        return sortedSamples[index]
    }

    /// The process's physical footprint (`task_vm_info.phys_footprint`, the
    /// figure Activity Monitor and jetsam use) and its lifetime peak
    /// (`ledger_phys_footprint_peak`). Unlike `ru_maxrss` the current value
    /// moves both ways, so a before/after pair isolates one workload. Returns
    /// zeros if the kernel query fails.
    private static func physicalFootprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let current = info.phys_footprint
        return (current, max(current, UInt64(max(0, info.ledger_phys_footprint_peak))))
    }
}
