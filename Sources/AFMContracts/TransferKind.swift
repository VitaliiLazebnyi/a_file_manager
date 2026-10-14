import AFMKernel
import Foundation

/// Services plugins offer each other through `Kernel.services`. The protocols live here, so
/// the plugin that offers one and the plugins that use it share only this module.

public enum TransferKind: Equatable, Sendable {
    case copy, move
}
