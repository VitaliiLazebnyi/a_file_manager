import Foundation
import os

/// What the window shell provides to plugins once it exists.
@MainActor
public protocol ShellServices: AnyObject {
    var panels: any PanelSet { get }
    var jobs: any JobService { get }
}
