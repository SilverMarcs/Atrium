import AppKit

/// The device around a simulator's screen, drawn from the bezels Xcode
/// installs in /Library/Developer/DeviceKit/Chrome: the case, the screen's
/// rounded shape, and the side buttons, which press the device's own.
/// Everything is in the device's points, upright, with the buttons' room
/// around the case.
///
/// Placement follows serve-sim's DeviceKit chrome reader
/// (https://github.com/EvanBacon/serve-sim, Apache-2.0).
struct SimulatorChrome {
    struct Button {
        let name: String
        let title: String
        let frame: CGRect
        let image: NSImage
        let imageDown: NSImage?
        let usagePage: UInt32
        let usage: UInt32
        let onTop: Bool
    }

    /// The whole drawing, buttons included.
    let size: CGSize
    let body: CGRect
    let screen: CGRect
    let bodyImage: NSImage?
    /// The screen's shape, rounded corners and all, to mask it with.
    let screenMask: NSImage?
    let screenCornerRadius: CGFloat
    let buttons: [Button]

    private static let chromeRoot = URL(filePath: "/Library/Developer/DeviceKit/Chrome")

    /// The simulator's own bezel, or a plain one when Xcode has none for it.
    @MainActor
    static func load(for device: NSObject, screen screenSize: CGSize) -> SimulatorChrome {
        let key = screenKey(device, screenSize)
        if let chrome = cache[key] { return chrome }
        let chrome = read(device: device, screen: screenSize) ?? plain(screen: screenSize)
        cache[key] = chrome
        return chrome
    }

    @MainActor private static var cache: [String: SimulatorChrome] = [:]

    private static func screenKey(_ device: NSObject, _ screen: CGSize) -> String {
        let type = (device.value(forKey: "deviceType") as? NSObject)?.value(forKey: "identifier") as? String ?? ""
        return "\(type) \(screen.width)x\(screen.height)"
    }

    /// A black case with rounded corners, for devices without a bezel.
    static func plain(screen: CGSize) -> SimulatorChrome {
        let inset: CGFloat = 14
        let body = CGRect(x: 0, y: 0, width: screen.width + inset * 2, height: screen.height + inset * 2)
        let radius = min(screen.width, screen.height) * 0.12
        let image = NSImage(size: body.size, flipped: true) { rect in
            NSColor(white: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius + inset, yRadius: radius + inset).fill()
            return true
        }
        return SimulatorChrome(
            size: body.size, body: body, screen: body.insetBy(dx: inset, dy: inset), bodyImage: image,
            screenMask: nil, screenCornerRadius: radius, buttons: []
        )
    }

    private static func read(device: NSObject, screen screenSize: CGSize) -> SimulatorChrome? {
        guard let type = device.value(forKey: "deviceType") as? NSObject,
              let typePath = type.value(forKey: "bundlePath") as? String else { return nil }
        let resources = URL(filePath: typePath).appending(path: "Contents/Resources")
        guard let profile = NSDictionary(contentsOf: resources.appending(path: "profile.plist")),
              let chromeID = profile["chromeIdentifier"] as? String else { return nil }
        let name = chromeID.replacingOccurrences(of: "com.apple.dt.devicekit.chrome.", with: "")
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let chromeResources = chromeRoot.appending(path: "\(name).devicechrome/Contents/Resources")
        guard let data = try? Data(contentsOf: chromeResources.appending(path: "chrome.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let images = json["images"] as? [String: Any] else { return nil }
        func pdf(_ name: Any?) -> NSImage? {
            (name as? String).flatMap { NSImage(contentsOf: chromeResources.appending(path: "\($0).pdf")) }
        }

        let sizing = images["sizing"] as? [String: Any] ?? [:]
        let insets = NSEdgeInsets(top: number(sizing["topHeight"]), left: number(sizing["leftWidth"]),
                                  bottom: number(sizing["bottomHeight"]), right: number(sizing["rightWidth"]))
        let padding = images["devicePadding"] as? [String: Any] ?? [:]
        let pad = NSEdgeInsets(top: number(padding["top"]), left: number(padding["left"]),
                               bottom: number(padding["bottom"]), right: number(padding["right"]))
        let outerRadius = number(((json["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any])?["cornerRadiusX"])

        // The case: one drawing, or nine pieces around the screen.
        let bodyImage: NSImage
        if let composite = pdf(images["composite"]) {
            bodyImage = composite
        } else if let sliced = nineSlice(images: images, pdf: pdf, size: CGSize(
            width: screenSize.width + insets.left + insets.right, height: screenSize.height + insets.top + insets.bottom)) {
            bodyImage = sliced
        } else {
            return nil
        }
        let body = CGRect(origin: CGPoint(x: pad.left, y: pad.top), size: bodyImage.size)
        let screen = CGRect(x: body.minX + (body.width - screenSize.width) / 2,
                            y: body.minY + (body.height - screenSize.height) / 2,
                            width: screenSize.width, height: screenSize.height)
        let mask = (profile["framebufferMask"] as? String).flatMap { NSImage(contentsOf: resources.appending(path: "\($0).pdf")) }

        let buttons = (json["inputs"] as? [[String: Any]] ?? []).compactMap { input -> Button? in
            guard let name = input["name"] as? String, let image = pdf(input["image"]),
                  let page = input["usagePage"] as? Int, let usage = input["usage"] as? Int else { return nil }
            let offsets = input["offsets"] as? [String: Any] ?? [:]
            let normal = point(offsets["normal"]) ?? point(offsets["rollover"]) ?? .zero
            let rollover = point(offsets["rollover"]) ?? normal
            let origin = buttonOrigin(anchor: input["anchor"] as? String ?? "left", trailing: input["align"] as? String == "trailing",
                                      normal: normal, rollover: rollover, image: image.size, body: body)
            return Button(
                name: name, title: input["accessibilityTitle"] as? String ?? name, frame: CGRect(origin: origin, size: image.size),
                image: image, imageDown: pdf(input["imageDown"]), usagePage: UInt32(page), usage: UInt32(usage),
                onTop: input["onTop"] as? Bool ?? false
            )
        }
        return SimulatorChrome(
            size: CGSize(width: body.maxX + pad.right, height: body.maxY + pad.bottom), body: body, screen: screen,
            bodyImage: bodyImage, screenMask: mask,
            screenCornerRadius: max(outerRadius - max(insets.left, insets.top), 0), buttons: buttons
        )
    }

    /// Where a side button sits: its rest place, mirrored from where it slides on hover.
    private static func buttonOrigin(anchor: String, trailing: Bool, normal: CGPoint, rollover: CGPoint,
                                     image: CGSize, body: CGRect) -> CGPoint {
        let rest = CGPoint(x: 2 * normal.x - rollover.x, y: 2 * normal.y - rollover.y)
        let alignedX = trailing ? body.maxX + rest.x - image.width : body.minX + rest.x
        switch anchor {
        case "right": return CGPoint(x: body.maxX + rest.x, y: body.minY + rest.y)
        case "top": return CGPoint(x: alignedX, y: body.minY + rest.y - image.height)
        case "bottom": return CGPoint(x: alignedX, y: body.maxY + rest.y)
        default: return CGPoint(x: body.minX + rollover.x - image.width / 2, y: body.minY + rollover.y)
        }
    }

    private static func nineSlice(images: [String: Any], pdf: (Any?) -> NSImage?, size: CGSize) -> NSImage? {
        guard let topLeft = pdf(images["topLeft"]), let top = pdf(images["top"]), let topRight = pdf(images["topRight"]),
              let right = pdf(images["right"]), let bottomRight = pdf(images["bottomRight"]), let bottom = pdf(images["bottom"]),
              let bottomLeft = pdf(images["bottomLeft"]), let left = pdf(images["left"]) else { return nil }
        return NSImage(size: size, flipped: true) { rect in
            let corner = topLeft.size
            let w = rect.width, h = rect.height
            topLeft.draw(in: CGRect(x: 0, y: 0, width: corner.width, height: corner.height))
            topRight.draw(in: CGRect(x: w - topRight.size.width, y: 0, width: topRight.size.width, height: topRight.size.height))
            bottomLeft.draw(in: CGRect(x: 0, y: h - bottomLeft.size.height, width: bottomLeft.size.width, height: bottomLeft.size.height))
            bottomRight.draw(in: CGRect(x: w - bottomRight.size.width, y: h - bottomRight.size.height,
                                        width: bottomRight.size.width, height: bottomRight.size.height))
            top.draw(in: CGRect(x: corner.width, y: 0, width: w - corner.width - topRight.size.width, height: top.size.height))
            bottom.draw(in: CGRect(x: bottomLeft.size.width, y: h - bottom.size.height,
                                   width: w - bottomLeft.size.width - bottomRight.size.width, height: bottom.size.height))
            left.draw(in: CGRect(x: 0, y: corner.height, width: left.size.width, height: h - corner.height - bottomLeft.size.height))
            right.draw(in: CGRect(x: w - right.size.width, y: topRight.size.height,
                                  width: right.size.width, height: h - topRight.size.height - bottomRight.size.height))
            // The middle, behind the screen.
            NSColor.black.setFill()
            CGRect(x: left.size.width, y: top.size.height, width: w - left.size.width - right.size.width,
                   height: h - top.size.height - bottom.size.height).fill()
            return true
        }
    }

    private static func number(_ value: Any?) -> CGFloat {
        (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    private static func point(_ value: Any?) -> CGPoint? {
        guard let value = value as? [String: Any] else { return nil }
        return CGPoint(x: number(value["x"]), y: number(value["y"]))
    }
}
