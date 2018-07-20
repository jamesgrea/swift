//===--- DriverUtils.swift ------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if os(Linux)
import Glibc
#else
import Darwin
#endif

import TestsUtils

struct BenchResults {
  let sampleCount, min, max, mean, sd, median, maxRSS: UInt64
}

public var registeredBenchmarks: [BenchmarkInfo] = []

enum TestAction {
  case run
  case listTests
  case help([String])
}

struct TestConfig {
  /// The delimiter to use when printing output.
  let delim: String

  /// The scalar multiple of the amount of times a test should be run. This
  /// enables one to cause tests to run for N iterations longer than they
  /// normally would. This is useful when one wishes for a test to run for a
  /// longer amount of time to perform performance analysis on the test in
  /// instruments.
  let iterationScale: Int

  /// If we are asked to have a fixed number of iterations, the number of fixed
  /// iterations.
  let fixedNumIters: UInt

  /// The number of samples we should take of each test.
  let numSamples: Int

  /// Is verbose output enabled?
  let verbose: Bool

  /// After we run the tests, should the harness sleep to allow for utilities
  /// like leaks that require a PID to run on the test harness.
  let afterRunSleep: Int?

  /// The list of tests to run.
  let tests: [(index: String, info: BenchmarkInfo)]

  let action: TestAction

  init(_ registeredBenchmarks: [BenchmarkInfo]) throws {

    struct PartialTestConfig {
      var delim: String?
      var tags, skipTags: Set<BenchmarkCategory>?
      var iterationScale, numSamples, afterRunSleep: Int?
      var fixedNumIters: UInt?
      var verbose: Bool?
      var action: TestAction?
      var tests: [String]?
    }

    let p = try ArgumentParser(into: PartialTestConfig(), validOptions: [
      "--iter-scale", "--num-samples", "--num-iters",
      "--verbose", "--delim", "--list", "--sleep",
      "--tags", "--skip-tags", "--help"
    ])

    func tags(tags: String) throws -> Set<BenchmarkCategory> {
      // We support specifying multiple tags by splitting on comma, i.e.:
      //  --tags=Array,Dictionary
      //  --skip-tags=Array,Set,unstable,skip
      return Set(
        try tags.split(separator: ",").map(String.init).map {
          try checked({ BenchmarkCategory(rawValue: $0) }, $0) })
    }

    // Parse command line arguments
    try p.parseArg("--iter-scale", \.iterationScale) { Int($0) }
    try p.parseArg("--num-iters", \.fixedNumIters) { UInt($0) }
    try p.parseArg("--num-samples", \.numSamples)  { Int($0) }
    try p.parseArg("--verbose", \.verbose, defaultValue: true)
    try p.parseArg("--delim", \.delim) { $0 }
    try p.parseArg("--tags", \PartialTestConfig.tags, parser: tags)
    try p.parseArg("--skip-tags", \PartialTestConfig.skipTags,
                    defaultValue: [], parser: tags)
    try p.parseArg("--sleep", \.afterRunSleep) { Int($0) }
    try p.parseArg("--list", \.action, defaultValue: .listTests)
    try p.parseArg("--help", \.action, defaultValue: .help(p.validOptions))
    try p.parseArg(nil, \.tests) // positional arguments

    let c = p.result

    // Configure from the command line arguments, filling in the defaults.
    delim = c.delim ?? ","
    iterationScale = c.iterationScale ?? 1
    fixedNumIters = c.fixedNumIters ?? 0
    numSamples = c.numSamples ?? 1
    verbose = c.verbose ?? false
    afterRunSleep = c.afterRunSleep
    action = c.action ?? .run
    tests = TestConfig.filterTests(registeredBenchmarks,
                                    specifiedTests: Set(c.tests ?? []),
                                    tags: c.tags ?? [],
                                    skipTags: c.skipTags ?? [.unstable, .skip])

    if verbose {
      let testList = tests.map({ $0.1.name }).joined(separator: ", ")
      print("""
            --- CONFIG ---
            NumSamples: \(numSamples)
            Verbose: \(verbose)
            IterScale: \(iterationScale)
            FixedIters: \(fixedNumIters)
            Tests Filter: \(c.tests ?? [])
            Tests to run: \(testList)

            --- DATA ---\n
            """)
    }
  }

  /// Returns the list of tests to run.
  ///
  /// - Parameters:
  ///   - registeredBenchmarks: List of all performance tests to be filtered.
  ///   - specifiedTests: List of explicitly specified tests to run. These can be
  ///     specified either by a test name or a test number.
  ///   - tags: Run tests tagged with all of these categories.
  ///   - skipTags: Don't run tests tagged with any of these categories.
  /// - Returns: An array of test number and benchmark info tuples satisfying
  ///     specified filtering conditions.
  static func filterTests(
    _ registeredBenchmarks: [BenchmarkInfo],
    specifiedTests: Set<String>,
    tags: Set<BenchmarkCategory>,
    skipTags: Set<BenchmarkCategory>
  ) -> [(index: String, info: BenchmarkInfo)] {
    let indices = Dictionary(uniqueKeysWithValues:
      zip(registeredBenchmarks.sorted().map { $0.name },
          (1...).lazy.map { String($0) } ))

    func byTags(b: BenchmarkInfo) -> Bool {
      return b.tags.isSuperset(of: tags) &&
        b.tags.isDisjoint(with: skipTags)
    }
    func byNamesOrIndices(b: BenchmarkInfo) -> Bool {
      return specifiedTests.contains(b.name) ||
        specifiedTests.contains(indices[b.name]!)
    } // !! "All registeredBenchmarks have been assigned an index"
    return registeredBenchmarks
      .filter(specifiedTests.isEmpty ? byTags : byNamesOrIndices)
      .map { (index: indices[$0.name]!, info: $0) }
  }
}

func internalMeanSD(_ inputs: [UInt64]) -> (UInt64, UInt64) {
  // If we are empty, return 0, 0.
  if inputs.isEmpty {
    return (0, 0)
  }

  // If we have one element, return elt, 0.
  if inputs.count == 1 {
    return (inputs[0], 0)
  }

  // Ok, we have 2 elements.

  var sum1: UInt64 = 0
  var sum2: UInt64 = 0

  for i in inputs {
    sum1 += i
  }

  let mean: UInt64 = sum1 / UInt64(inputs.count)

  for i in inputs {
    sum2 = sum2 &+ UInt64((Int64(i) &- Int64(mean))&*(Int64(i) &- Int64(mean)))
  }

  return (mean, UInt64(sqrt(Double(sum2)/(Double(inputs.count) - 1))))
}

func internalMedian(_ inputs: [UInt64]) -> UInt64 {
  return inputs.sorted()[inputs.count / 2]
}

#if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER

@_silgen_name("_swift_leaks_startTrackingObjects")
func startTrackingObjects(_: UnsafePointer<CChar>) -> ()
@_silgen_name("_swift_leaks_stopTrackingObjects")
func stopTrackingObjects(_: UnsafePointer<CChar>) -> Int

#endif

#if os(Linux)
class Timer {
  typealias TimeT = timespec
  func getTime() -> TimeT {
    var ticks = timespec(tv_sec: 0, tv_nsec: 0)
    clock_gettime(CLOCK_REALTIME, &ticks)
    return ticks
  }
  func diffTimeInNanoSeconds(from start_ticks: TimeT, to end_ticks: TimeT) -> UInt64 {
    var elapsed_ticks = timespec(tv_sec: 0, tv_nsec: 0)
    if end_ticks.tv_nsec - start_ticks.tv_nsec < 0 {
      elapsed_ticks.tv_sec = end_ticks.tv_sec - start_ticks.tv_sec - 1
      elapsed_ticks.tv_nsec = end_ticks.tv_nsec - start_ticks.tv_nsec + 1000000000
    } else {
      elapsed_ticks.tv_sec = end_ticks.tv_sec - start_ticks.tv_sec
      elapsed_ticks.tv_nsec = end_ticks.tv_nsec - start_ticks.tv_nsec
    }
    return UInt64(elapsed_ticks.tv_sec) * UInt64(1000000000) + UInt64(elapsed_ticks.tv_nsec)
  }
}
#else
class Timer {
  typealias TimeT = UInt64
  var info = mach_timebase_info_data_t(numer: 0, denom: 0)
  init() {
    mach_timebase_info(&info)
  }
  func getTime() -> TimeT {
    return mach_absolute_time()
  }
  func diffTimeInNanoSeconds(from start_ticks: TimeT, to end_ticks: TimeT) -> UInt64 {
    let elapsed_ticks = end_ticks - start_ticks
    return elapsed_ticks * UInt64(info.numer) / UInt64(info.denom)
  }
}
#endif

class SampleRunner {
  let timer = Timer()
  let baseline = SampleRunner.usage()
  let c: TestConfig

  init(_ config: TestConfig) {
    self.c = config
  }

  private static func usage() -> rusage {
    var u = rusage(); getrusage(RUSAGE_SELF, &u); return u
  }

  /// Returns maximum resident set size (MAX_RSS) delta in bytes
  func measureMemoryUsage() -> Int {
      var current = SampleRunner.usage()
      let maxRSS = current.ru_maxrss - baseline.ru_maxrss

      if c.verbose {
        let pages = maxRSS / sysconf(_SC_PAGESIZE)
        func deltaEquation(_ stat: KeyPath<rusage, Int>) -> String {
          let b = baseline[keyPath: stat], c = current[keyPath: stat]
          return "\(c) - \(b) = \(c - b)"
        }
        print("""
                  MAX_RSS \(deltaEquation(\rusage.ru_maxrss)) (\(pages) pages)
                  ICS \(deltaEquation(\rusage.ru_nivcsw))
                  VCS \(deltaEquation(\rusage.ru_nvcsw))
              """)
      }
      return maxRSS
  }

  func run(_ name: String, fn: (Int) -> Void, num_iters: UInt) -> UInt64 {
    // Start the timer.
#if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER
    name.withCString { p in startTrackingObjects(p) }
#endif
    let start_ticks = timer.getTime()
    fn(Int(num_iters))
    // Stop the timer.
    let end_ticks = timer.getTime()
#if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER
    name.withCString { p in stopTrackingObjects(p) }
#endif

    // Compute the spent time and the scaling factor.
    return timer.diffTimeInNanoSeconds(from: start_ticks, to: end_ticks)
  }
}

/// Invoke the benchmark entry point and return the run time in milliseconds.
func runBench(_ test: BenchmarkInfo, _ c: TestConfig) -> BenchResults? {
  var samples = [UInt64](repeating: 0, count: c.numSamples)

  // Before we do anything, check that we actually have a function to
  // run. If we don't it is because the benchmark is not supported on
  // the platform and we should skip it.
  guard let testFn = test.runFunction else {
    if c.verbose {
	print("Skipping unsupported benchmark \(test.name)!")
    }
    return nil
  }

  if c.verbose {
    print("Running \(test.name) for \(c.numSamples) samples.")
  }

  let sampler = SampleRunner(c)
  for s in 0..<c.numSamples {
    test.setUpFunction?()
    let time_per_sample: UInt64 = 1_000_000_000 * UInt64(c.iterationScale)

    var scale : UInt
    var elapsed_time : UInt64 = 0
    if c.fixedNumIters == 0 {
      elapsed_time = sampler.run(test.name, fn: testFn, num_iters: 1)

      if elapsed_time > 0 {
        scale = UInt(time_per_sample / elapsed_time)
      } else {
        if c.verbose {
          print("    Warning: elapsed time is 0. This can be safely ignored if the body is empty.")
        }
        scale = 1
      }
    } else {
      // Compute the scaling factor if a fixed c.fixedNumIters is not specified.
      scale = c.fixedNumIters
      if scale == 1 {
        elapsed_time = sampler.run(test.name, fn: testFn, num_iters: 1)
      }
    }
    // Make integer overflow less likely on platforms where Int is 32 bits wide.
    // FIXME: Switch BenchmarkInfo to use Int64 for the iteration scale, or fix
    // benchmarks to not let scaling get off the charts.
    scale = min(scale, UInt(Int.max) / 10_000)

    // Rerun the test with the computed scale factor.
    if scale > 1 {
      if c.verbose {
        print("    Measuring with scale \(scale).")
      }
      elapsed_time = sampler.run(test.name, fn: testFn, num_iters: scale)
    } else {
      scale = 1
    }
    // save result in microseconds or k-ticks
    samples[s] = elapsed_time / UInt64(scale) / 1000
    if c.verbose {
      print("    Sample \(s),\(samples[s])")
    }
    test.tearDownFunction?()
  }

  let (mean, sd) = internalMeanSD(samples)

  // Return our benchmark results.
  return BenchResults(sampleCount: UInt64(samples.count),
                      min: samples.min()!, max: samples.max()!,
                      mean: mean, sd: sd, median: internalMedian(samples),
                      maxRSS: UInt64(sampler.measureMemoryUsage()))
}

/// Execute benchmarks and continuously report the measurement results.
func runBenchmarks(_ c: TestConfig) {
  let withUnit = {$0 + "(us)"}
  let header = (
    ["#", "TEST", "SAMPLES"] +
    ["MIN", "MAX", "MEAN", "SD", "MEDIAN"].map(withUnit)
    + ["MAX_RSS(B)"]
  ).joined(separator: c.delim)
  print(header)

  var testCount = 0

  func report(_ index: String, _ t: BenchmarkInfo, results: BenchResults?) {
    func values(r: BenchResults) -> [String] {
      return [r.sampleCount, r.min, r.max, r.mean, r.sd, r.median, r.maxRSS]
        .map { String($0) }
    }
    let benchmarkStats = (
      [index, t.name] + (results.map(values) ?? ["Unsupported"])
    ).joined(separator: c.delim)

    print(benchmarkStats)
    fflush(stdout)

    if (results != nil) {
      testCount += 1
    }
  }

  for (index, test) in c.tests {
    report(index, test, results:runBench(test, c))
  }

  print("")
  print("Totals\(c.delim)\(testCount)")
}

public func main() {
  do {
    let config = try TestConfig(registeredBenchmarks)
    switch (config.action) {
    case let .help(validOptions):
      print("Valid options:")
      for v in validOptions {
        print("    \(v)")
      }
    case .listTests:
      print("#\(config.delim)Test\(config.delim)[Tags]")
      for (index, t) in config.tests {
      let testDescription = [String(index), t.name, t.tags.sorted().description]
        .joined(separator: config.delim)
      print(testDescription)
      }
    case .run:
      runBenchmarks(config)
      if let x = config.afterRunSleep {
        sleep(UInt32(x))
      }
    }
  } catch let error as ArgumentError {
    fflush(stdout)
    fputs("\(error)\n", stderr)
    fflush(stderr)
    exit(1)
  } catch {
    fatalError("\(error)")
  }
}
