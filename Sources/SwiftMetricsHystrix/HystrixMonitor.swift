import Foundation
import SwiftMetrics
import CircuitBreaker
import KituraNet
import LoggerAPI
import KituraWebSocket

public class SwiftMetricsCircuitBreaker: HystrixMonitor {

  /// Weak references to monitored circuit breakers
  public var refs: [Weak] = []

  /// Port used for web socket connection (Default 8081)
  public var port: Int

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
  ///   - port: The port to listen on.
  public init(swiftMetricsInstance: SwiftMetrics, port: Int = 8081) {
    instance = swiftMetricsInstance
    self.port = port
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
  private func sendSnapshots() {
    self.refs = self.refs.filter {
      if let breaker = $0.value {
        self.emit(snapshot: breaker.hystrixSnapshot)
        return true
      }
      return false
    }
  }

  /// Registers websocket instance and begins listening
  private func instantiateServer() {
    WebSocket.register(service: self, onPath: "hystrix.stream")

    let server = HTTP.createServer()
    server.delegate = self

    do {
      try server.listen(on: port)
      ListenerGroup.waitForListeners()
    } catch {
      Log.error("Error listening on port 8081: \(error).")
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

/// Conformance to Server Delegate Protocol
extension SwiftMetricsCircuitBreaker: ServerDelegate {

  /// Server Delegate Protocol Handler
  public func handle(request: ServerRequest, response: ServerResponse) {
    Log.entry("Received message to server delegate handle")
  }
}

/// WebSocketService conformance extension
extension SwiftMetricsCircuitBreaker: WebSocketService {

  /// Method called when a new connection is made
  public func connected(connection: WebSocketConnection) {
    connections[connection.id] = connection
  }

  /// Method called when a connection is disconnected
  public func disconnected(connection: WebSocketConnection, reason: WebSocketCloseReasonCode) {
    connections.removeValue(forKey: connection.id)
  }

  /// Method called when a data message has been received
  public func received(message: Data, from: WebSocketConnection) {
    Log.entry("Received message from connection: \(message.count)")
  }

  /// Method called when a string message has been received
  public func received(message: String, from: WebSocketConnection) {
    Log.entry("Received message from connection: \(message)")
  }
}
