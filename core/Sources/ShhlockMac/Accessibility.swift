// Reads the focused login field of whatever app is in front, using the macOS Accessibility API,
// and fills it. This is what lets Shhlock work in Safari, Chrome, Firefox, Arc … without an extension.

import AppKit
import ApplicationServices
import Foundation

struct FocusedForm: Equatable {
    var app: NSRunningApplication
    var password: AXUIElement?
    var username: AXUIElement?
    var origin: String          // "https://github.com" — or "app://bundle.id" outside a browser
    var frame: CGRect           // screen rect (AppKit coordinates) of the field to anchor UI to
    var isSignup: Bool

    static func == (a: FocusedForm, b: FocusedForm) -> Bool {
        a.app.processIdentifier == b.app.processIdentifier && a.origin == b.origin && a.password == b.password && a.username == b.username
    }
}

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func attr<T>(_ element: AXUIElement, _ name: String, as _: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return (value as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? { attr(element, name, as: String.self) }

    static func rect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)  // swiftlint:disable:this force_cast
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)  // swiftlint:disable:this force_cast
        // AX uses a top-left origin on the main display; AppKit uses bottom-left
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: point.x, y: mainHeight - point.y - size.height, width: size.width, height: size.height)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attr(element, kAXChildrenAttribute, as: [AXUIElement].self) ?? []
    }

    static func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) ?? "" }
    static func subrole(_ e: AXUIElement) -> String { string(e, kAXSubroleAttribute) ?? "" }

    /// Everything a field says about itself, lower-cased, for guessing what it is for.
    static func hints(_ e: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXHelpAttribute, "AXDOMIdentifier"]
            .compactMap { string(e, $0) }.joined(separator: " ").lowercased()
    }

    static func isPasswordField(_ e: AXUIElement) -> Bool {
        role(e) == kAXTextFieldRole && (subrole(e) == kAXSecureTextFieldSubrole || hints(e).contains("password"))
    }

    static func isUsernameField(_ e: AXUIElement) -> Bool {
        guard role(e) == kAXTextFieldRole, subrole(e) != kAXSecureTextFieldSubrole else { return false }
        let h = hints(e)
        return h.contains("user") || h.contains("email") || h.contains("login") || h.contains("account") || h.contains("phone") || h.contains("identifier")
    }

    /// Walks up to the enclosing web page (AXWebArea) and returns its URL, or nil outside a browser.
    static func pageURL(from element: AXUIElement) -> (URL, AXUIElement)? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let e = current else { break }
            if role(e) == "AXWebArea" {
                if let url = attr(e, "AXURL", as: URL.self) ?? string(e, kAXDocumentAttribute).flatMap(URL.init(string:)) {
                    return (url, e)
                }
                return nil
            }
            current = self.element(e, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth-first search below `root` for the first element matching `test`, bounded so pages cannot stall us.
    static func find(in root: AXUIElement, limit: Int = 900, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let e = queue.removeFirst()
            seen += 1
            if test(e) { return e }
            queue.append(contentsOf: children(e))
        }
        return nil
    }

    static func allPasswordFields(in root: AXUIElement, limit: Int = 900) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue = [root]
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let e = queue.removeFirst()
            seen += 1
            if isPasswordField(e) { out.append(e) }
            queue.append(contentsOf: children(e))
        }
        return out
    }

    @discardableResult
    static func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Types text into whatever has keyboard focus — the fallback for pages that ignore AX value changes.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(4000)
        }
    }

    /// Presses Return in whatever has focus — submits the login form the way a person would.
    static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// What the frontmost app is showing: a login form, or nothing of interest.
    static func focusedForm() -> FocusedForm? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = element(appElement, kAXFocusedUIElementAttribute) else { return nil }
        guard role(focused) == kAXTextFieldRole else { return nil }

        let isPassword = isPasswordField(focused)
        let isUser = isUsernameField(focused)
        guard isPassword || isUser else { return nil }

        var origin: String
        var scope: AXUIElement
        if let (url, webArea) = pageURL(from: focused) {
            guard let scheme = url.scheme, let host = url.host, scheme == "https" || scheme == "http" else { return nil }
            origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
            scope = webArea
        } else {
            guard let bundle = app.bundleIdentifier else { return nil }
            origin = "app://" + bundle
            scope = element(appElement, kAXFocusedWindowAttribute) ?? appElement
        }

        let passwords = allPasswordFields(in: scope)
        let password = isPassword ? focused : passwords.first
        let username = isUser ? focused : find(in: scope) { isUsernameField($0) }
        let anchor = isPassword ? focused : (username ?? focused)
        guard let frame = rect(anchor) else { return nil }
        let signup = passwords.count > 1 || (password.map { hints($0).contains("new") || hints($0).contains("confirm") } ?? false)
        return FocusedForm(app: app, password: password, username: username, origin: origin, frame: frame, isSignup: signup)
    }
}
