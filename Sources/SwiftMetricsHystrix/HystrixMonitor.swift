import Foundation
import SwiftMetrics
import CircuitBreaker
import KituraRequest

public class SwiftMetricsCircuitBreaker: Monitor {

  /// Weak references to monitored circuit breakers
  public var refs: [Weak] = []

  public var endpoint: URL

  /// Default interval to emit circuit breaker updates
  public var snapshotDelay: Int = 1200

  private var snapshotTimer: DispatchSourceTimer?

  private let queue = DispatchQueue(label: "Hystrix Queue", attributes: .concurrent)

  private let instance: SwiftMetrics

  /// Initializer
  ///
  /// - Parameter:
  ///   - swiftMetricsInstance: SwiftMetrics instance
  ///   - endpoint: The endpoint for the swift metrics instance
  init(swiftMetricsInstance: SwiftMetrics, endpoint: URL) {
    instance = swiftMetricsInstance
    self.endpoint = endpoint
  }

  /// Initializer
  ///
  /// - Parameter:
  ///   - swiftMetricsInstance: SwiftMetrics instance
  ///   - endpoint: The endpoint for the swift metrics instance
  init?(swiftMetricsInstance: SwiftMetrics, endpoint: String = "https://localhost:9002") {
    instance = swiftMetricsInstance
    self.endpoint = URL(string: endpoint)!
  }

  /// Registers a circuit breaker to be monitored
  ///
  /// - Parameters
  ///   - breakerRef: A reference to a CircuitBreaker instance
  public func register(breakerRef: HystrixProvider) {
    self.refs.append(Weak(value: breakerRef))
  }

  /// Begins emitting snapshots
  public func startSnapshots() {
    startResetTimer()
  }

  /// Stops emitting snapshots
  public func stopSnapshots() {
    snapshotTimer?.cancel()
  }

  /// Method to filter circuit breaker refs and emit snapshots
  public func sendSnapshots() {
    self.refs = self.refs.filter {
      if let breaker = $0.value {
        self.emit(snapshot: breaker.hystrixSnapshot)
        return true
      }
      return false
    }
  }


  /// Emits a hystrix json object to the server
  ///
  /// - Parameters
  ///   - snapshot: A hystrix compliant [String: Any] dictionary
  public func emit(snapshot: [String: Any]) {
    KituraRequest.request(Request.Method.post, endpoint.absoluteString, parameters: snapshot, encoding: JSONEncoding.default, headers: [:]).response {
      request, response, data, error in
      print(request, response, data, error)
    }
  }

  /// Hystric Emit Timer Setup Method
  private func startResetTimer() {

    // Cancel previous timer if any
    snapshotTimer?.cancel()

    snapshotTimer = DispatchSource.makeTimerSource(queue: queue)

    snapshotTimer?.setEventHandler { [weak self] in
      self?.sendSnapshots()
    }

    snapshotTimer?.schedule(deadline: .now() + .milliseconds(snapshotDelay))

    snapshotTimer?.resume()
  }
}
