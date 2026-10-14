import AppKit

@main
struct MenuBarDismissalTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Offscreen windows exercise AppKit events without covering the desktop.
        let frame = NSRect(x: -10000, y: -10000, width: 300, height: 200)
        let menu = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let dashboard = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        dashboard.isReleasedWhenClosed = false
        defer { menu.close(); dashboard.close() }
        let controller = MenuBarDismissalController(window: menu)
        controller.start()
        defer { controller.stop() }

        func click(_ window: NSWindow, type: NSEvent.EventType = .leftMouseDown) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            app.sendEvent(event)
        }
        menu.orderFront(nil)
        dashboard.orderFront(nil)
        click(menu)
        guard menu.isVisible else { fatalError("Clicking a menu control dismissed the menu") }
        let child = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        menu.addChildWindow(child, ordered: .above)
        click(child)
        guard menu.isVisible else { fatalError("Clicking a menu child window dismissed the menu") }
        menu.removeChildWindow(child)
        child.close()
        click(dashboard)
        guard !menu.isVisible, dashboard.isVisible else {
            print("FAIL: clicking another app window did not close only the menu")
            exit(1)
        }
        menu.orderFront(nil)
        click(menu)
        guard menu.isVisible else { fatalError("Reopening the menu lost inside-click handling") }
        click(dashboard, type: .rightMouseDown)
        guard !menu.isVisible else { fatalError("Outside right click left the menu open") }

        // The status item toggles the menu itself; closing it first would reopen it.
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        guard let statusWindow = statusItem.button?.window else { fatalError("Missing status item window") }
        menu.orderFront(nil)
        click(statusWindow)
        guard menu.isVisible else { fatalError("Clicking the menu bar icon closed the menu before it could toggle") }

        dashboard.orderOut(nil)
        menu.orderFront(nil)
        MenuBarDismissalController.performNavigation {
            guard !menu.isVisible else {
                fatalError("Navigation ran before the menu was dismissed")
            }
            dashboard.orderFront(nil)
        }
        guard dashboard.isVisible else { fatalError("Navigation did not open its destination") }

        menu.orderFront(nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        guard !menu.isVisible, dashboard.isVisible else { fatalError("Switching to another application left the menu open") }

        controller.stop()
        menu.orderFront(nil)
        click(dashboard)
        guard menu.isVisible else { fatalError("Detached menu monitor kept dismissing windows") }
        MenuBarDismissalController.performNavigation {}
        guard menu.isVisible else { fatalError("Detached navigation observer kept dismissing windows") }
        print("PASS: outside clicks and navigation dismiss only the menu, inside controls work, and observers detach")
    }
}
