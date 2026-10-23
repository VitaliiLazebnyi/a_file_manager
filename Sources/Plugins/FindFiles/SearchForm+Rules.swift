import AFMKernel
import AppKit

/// The rule rows of the Plugins tab.
extension SearchForm {
    /// Adds a row below the others, showing `rule` (nil: a row of its own, the first field and operator).
    internal func addRuleRow(_ rule: FieldRule?) {
        let stack = NSStackView()
        stack.spacing = 8
        let row = RuleRow(view: stack)
        row.field.addItems(withTitles: fields.map(\.title))
        row.comparison.addItems(withTitles: FieldRule.Operator.allCases.map(\.title))
        row.value.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for control in [row.field, row.comparison, row.value] {
            stack.addArrangedSubview(control)
        }
        if let rule {
            row.field.selectItem(at: fields.firstIndex { $0.id == rule.field } ?? 0)
            row.comparison.selectItem(at: rule.comparison.rawValue)
            row.value.stringValue = rule.value
        }
        ruleRows.append(row)
        rulesStack.addArrangedSubview(stack)
        updateEnabled()
    }

    /// Takes a row off the page.
    internal func remove(_ row: RuleRow) {
        rulesStack.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
    }

    /// "More rules": one more row.
    @objc
    internal func moreRules() { addRuleRow(nil) }

    /// "Fewer rules": the last row goes, unless it is the only one.
    @objc
    internal func fewerRules() {
        if ruleRows.count > 1, let row = ruleRows.popLast() {
            remove(row)
        }
    }
}
