/// Typed services one plugin offers to the others, found by their protocol.
///
/// Main thread.
@preconcurrency
@MainActor
public final class ServiceRegistry {
    private var services: [ObjectIdentifier: Any] = [:]

    /// Offers `service` under the protocol `type` (`(any ViewerService).self`).
    ///
    /// Offering one protocol twice is a bug of the plugins.
    public func register<Service>(_ type: Service.Type, _ service: Service) {
        precondition(services[ObjectIdentifier(type)] == nil, "The service \(type) is offered twice")
        services[ObjectIdentifier(type)] = service
    }

    /// The service offered under the protocol `type`; nil when no plugin offers it.
    public func find<Service>(_ type: Service.Type) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }

    deinit {
        // Nothing to release.
    }
}
