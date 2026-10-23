import AppKit

/// A stack whose parts fill it: across, every part is as wide (or as high) as the stack, and
/// along it the parts without a size of their own (lists, spacers) take the room that is left.
@MainActor
internal func filledStack(_ views: [NSView], vertical: Bool, spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.distribution = .fill
    stack.alignment = vertical ? .leading : .top
    stack.spacing = spacing
    for view in views {
        if vertical {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if view is NSScrollView || view is NSStackView {
            view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }
    return stack
}

/// A view with a margin around it, as the content of a window.
@MainActor
internal func padded(_ view: NSView, by margin: CGFloat) -> NSView {
    let holder = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: holder.topAnchor, constant: margin),
        view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: margin),
        view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -margin),
        view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -margin)
    ])
    return holder
}

/// Takes the room nothing else wants.
@MainActor
internal func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    return view
}
