import Foundation
import os

/// Typed services one plugin offers to the others, found by their protocol.
@MainActor
public final class ServiceRegistry {
    private var services: [ObjectIdentifier: Any] = [:]

    public func register<Service>(_ type: Service.Type, _ service: Service) {
        precondition(services[ObjectIdentifier(type)] == nil, "The service \(type) is offered twice")
        services[ObjectIdentifier(type)] = service
    }

    public func find<Service>(_ type: Service.Type) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }
}
