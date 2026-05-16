import AppKit

enum ActivationPolicyDecider {
    static func policy(hideDockIcon: Bool, hasStatusItem: Bool) -> NSApplication.ActivationPolicy {
        hideDockIcon && hasStatusItem ? .accessory : .regular
    }
}

