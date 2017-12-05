import Foundation
import SwiftMetrics
import CircuitBreaker
import KituraNet
import LoggerAPI
import KituraWebSocket
import Kitura

public class SwiftMetricsCircuitBreaker: HystrixMonitor, ServerDelegate {

  /// Weak references to monitored circuit breakers
  public var refs: [Weak] = []

  public var endpoint: URL

  /// Default interval to emit circuit breaker updates
  public var snapshotDelay: Int = 1200

  private var snapshotTimer: DispatchSourceTimer?

  private let queue = DispatchQueue(label: "Hystrix Queue", attributes: .concurrent)

  private let instance: SwiftMetrics

  private var connections = [String: WebSocketConnection]()

  /// Initializer
  ///
  /// - Parameter:
  ///   - swiftMetricsInstance: SwiftMetrics instance
  ///   - endpoint: The endpoint for the swift metrics instance
  public init(swiftMetricsInstance: SwiftMetrics, endpoint: URL) {
    instance = swiftMetricsInstance
    self.endpoint = endpoint
  }

  /// Initializer
  ///
  /// - Parameter:
  ///   - swiftMetricsInstance: SwiftMetrics instance
  ///   - endpoint: The endpoint for the swift metrics instance
  public init?(swiftMetricsInstance: SwiftMetrics, endpoint: String = "https://localhost:9002") {
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
    instantiateServer()
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

  public func handle(request: ServerRequest, response: ServerResponse) {}

  private func instantiateServer() {
    WebSocket.register(service: self, onPath: "hystrix.stream")

    let server = HTTP.createServer()
    server.delegate = self

    do {
      try server.listen(on: 8081)
      ListenerGroup.waitForListeners()
    } catch {
      Log.error("Error listening on port 8080: \(error).")
    }
  }

  /// Emits a hystrix json object to our web socket connections
  ///
  /// - Parameters
  ///   - snapshot: A hystrix compliant [String: Any] dictionary
  private func emit(snapshot: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .prettyPrinted) else {
      Log.error("Invalid JSON found in Hystrix snapshot")
      return
    }

    for (_, conn) in connections { conn.send(message: data) }
  }

  /// Hystric Emit Timer Setup Method
  private func startResetTimer() {

    // Cancel previous timer if any
    snapshotTimer?.cancel()

    snapshotTimer = DispatchSource.makeTimerSource(queue: queue)

    snapshotTimer?.setEventHandler { [weak self] in
      self?.sendSnapshots()
      self?.startResetTimer()
    }

    snapshotTimer?.schedule(deadline: .now() + .milliseconds(snapshotDelay))

    snapshotTimer?.resume()
  }
}

/// WebSocketService conformance extension
extension SwiftMetricsCircuitBreaker: WebSocketService {

  public func connected(connection: WebSocketConnection) {
    connections[connection.id] = connection
  }

  public func disconnected(connection: WebSocketConnection, reason: WebSocketCloseReasonCode) {
    connections.removeValue(forKey: connection.id)
  }

  public func received(message: Data, from: WebSocketConnection) {
    Log.entry("Received message from connection: \(message.count)")
  }

  public func received(message: String, from: WebSocketConnection) {
    Log.entry("Received message from connection: \(message)")
  }
}
