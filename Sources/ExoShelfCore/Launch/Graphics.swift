import Foundation

/// How a game's picture is upscaled and presented, for both emulators.
///
/// DOSBox Staging gets these as `[render]` and `[sdl]` settings, layered over
/// eXo's config; ScummVM gets them as command-line options. Each value has a
/// neutral setting ("as configured", `auto`) that leaves the game's own
/// config and the user's emulator defaults alone, so a fresh
/// `GraphicsSettings()` changes only the upscaler.
public struct GraphicsSettings: Codable, Sendable, Hashable {
    public var style: UpscaleStyle = .sharp
    public var aspect: AspectMode = .auto
    public var integerScaling: IntegerScaling = .auto
    /// Blends CGA/EGA checkerboard dithering into solid colour, 0 (off) to 100.
    public var dedithering: Int = 0
    public var deinterlacing: Deinterlacing = .off
    public var colorProfile: ColorProfile = .auto
    public var monochromePalette: MonochromePalette = .asConfigured
    public var cgaPalette: CGAPalette = .asConfigured
    public var windowSize: WindowSize = .automatic
    /// ScummVM's scaler factor; each scaler caps it at what it supports.
    public var scaleFactor: Int = 3

    public init(style: UpscaleStyle = .sharp) {
        self.style = style
    }

    /// Missing keys take their defaults, so settings saved by an older
    /// version keep loading as options are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decodeIfPresent(UpscaleStyle.self, forKey: .style)) ?? .sharp
        aspect = (try? c.decodeIfPresent(AspectMode.self, forKey: .aspect)) ?? .auto
        integerScaling = (try? c.decodeIfPresent(IntegerScaling.self, forKey: .integerScaling)) ?? .auto
        dedithering = min(100, max(0, (try? c.decodeIfPresent(Int.self, forKey: .dedithering)) ?? 0))
        deinterlacing = (try? c.decodeIfPresent(Deinterlacing.self, forKey: .deinterlacing)) ?? .off
        colorProfile = (try? c.decodeIfPresent(ColorProfile.self, forKey: .colorProfile)) ?? .auto
        monochromePalette = (try? c.decodeIfPresent(MonochromePalette.self, forKey: .monochromePalette)) ?? .asConfigured
        cgaPalette = (try? c.decodeIfPresent(CGAPalette.self, forKey: .cgaPalette)) ?? .asConfigured
        windowSize = (try? c.decodeIfPresent(WindowSize.self, forKey: .windowSize)) ?? .automatic
        scaleFactor = min(4, max(1, (try? c.decodeIfPresent(Int.self, forKey: .scaleFactor)) ?? 3))
    }

    // MARK: - DOSBox Staging

    /// `[sdl]` and `[render]` settings for DOSBox Staging, or "" when every
    /// choice is neutral.
    public func dosboxConfig() -> String {
        var sdl: [String] = []
        var render: [String] = []
        if let shader = style.dosboxShader {
            render.append("shader=\(shader)")
            // Shaders only run on the OpenGL output; some eXo configs pick texture.
            sdl.append("output=opengl")
        }
        if aspect != .auto { render.append("aspect=\(aspect.dosboxValue)") }
        if integerScaling != .auto { render.append("integer_scaling=\(integerScaling.rawValue)") }
        if dedithering > 0 { render.append("dedithering=\(dedithering >= 100 ? "on" : String(dedithering))") }
        if deinterlacing != .off { render.append("deinterlacing=\(deinterlacing.rawValue)") }
        if colorProfile != .auto { render.append("crt_color_profile=\(colorProfile.rawValue)") }
        if monochromePalette != .asConfigured { render.append("monochrome_palette=\(monochromePalette.rawValue)") }
        if let cga = cgaPalette.dosboxValue { render.append("cga_colors=\(cga)") }
        if windowSize != .automatic { sdl.append("window_size=\(windowSize.rawValue)") }

        var out = ""
        if !sdl.isEmpty { out += "[sdl]\n" + sdl.joined(separator: "\n") + "\n" }
        if !render.isEmpty { out += "[render]\n" + render.joined(separator: "\n") + "\n" }
        return out
    }

    /// Settings of eXo's config that would beat these, by section: Staging
    /// applies deprecated aliases (`glshader`, `windowresolution`) after
    /// every config file has loaded, so a later `shader=` loses to them.
    /// The launch removes them from its copy of eXo's config.
    public var supersededKeys: [String: Set<String>] {
        var keys: [String: Set<String>] = [:]
        if style.dosboxShader != nil {
            keys["render", default: []].formUnion(["glshader", "shader"])
            keys["sdl", default: []].insert("output")
        }
        if windowSize != .automatic { keys["sdl", default: []].formUnion(["windowresolution", "window_size"]) }
        return keys
    }

    // MARK: - ScummVM

    /// ScummVM options for the same choices. ScummVM has no CRT shaders
    /// without a shader pack, so the CRT styles use its TV scanline scaler.
    public func scummvmArguments() -> [String] {
        var args: [String] = []
        switch aspect {
        case .auto: args.append("--aspect-ratio")
        case .squarePixels: args.append("--no-aspect-ratio")
        case .stretch: args.append("--aspect-ratio")
        }
        guard let scaler = style.scummvmScaler else {
            if aspect == .stretch { args.append("--stretch-mode=stretch") }
            return args
        }
        args.append("--scaler=\(scaler.name)")
        args.append("--scale-factor=\(min(max(scaleFactor, scaler.minFactor), scaler.maxFactor))")
        args.append(style.filtered ? "--filtering" : "--no-filtering")
        let stretch: String
        if aspect == .stretch {
            stretch = "stretch"
        } else if integerScaling == .off || style.filtered {
            stretch = "fit"
        } else {
            stretch = "pixel-perfect"
        }
        args.append("--stretch-mode=\(stretch)")
        return args
    }
}

/// The upscaler. Pixel-art scalers redraw edges at a higher resolution;
/// interpolation filters scale the image as a photo; CRT styles emulate the
/// monitor the game was made for.
public enum UpscaleStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case sharp
    case nearest
    case xbr
    case xbrNoBlend
    case xbr3D
    case scale3x
    case advInterp
    case catmullRom
    case bilinear
    case crt
    case crtMachine
    case crtArcade
    case crtArcadeSharp
    case asConfigured

    public var id: String { rawValue }

    public enum Family: String, Sendable, CaseIterable {
        case pixel = "Pixels"
        case pixelArt = "Pixel-art upscalers"
        case smooth = "Smoothing"
        case crt = "CRT monitor"
        case none = "Other"
    }

    public var family: Family {
        switch self {
        case .sharp, .nearest: return .pixel
        case .xbr, .xbrNoBlend, .xbr3D, .scale3x, .advInterp: return .pixelArt
        case .catmullRom, .bilinear: return .smooth
        case .crt, .crtMachine, .crtArcade, .crtArcadeSharp: return .crt
        case .asConfigured: return .none
        }
    }

    public var title: String {
        switch self {
        case .sharp: return "Sharp pixels"
        case .nearest: return "Nearest neighbour"
        case .xbr: return "xBR"
        case .xbrNoBlend: return "xBR, no blending"
        case .xbr3D: return "xBR 3D"
        case .scale3x: return "Scale3x (AdvMAME)"
        case .advInterp: return "AdvInterp / HQ"
        case .catmullRom: return "Catmull-Rom"
        case .bilinear: return "Bilinear"
        case .crt: return "Adaptive CRT"
        case .crtMachine: return "CRT for the emulated card"
        case .crtArcade: return "Arcade monitor"
        case .crtArcadeSharp: return "Arcade monitor, sharp"
        case .asConfigured: return "As configured"
        }
    }

    public var summary: String {
        switch self {
        case .sharp: return "Crisp square pixels at the right aspect ratio, with minimal blur. Closest to eXo's own setup."
        case .nearest: return "The sharpest picture; pixels can come out unevenly sized."
        case .xbr: return "Rebuilds diagonal edges and curves at high resolution. Smooth, clean pixel art."
        case .xbrNoBlend: return "xBR edge reconstruction without colour blending: smooth lines, hard colours."
        case .xbr3D: return "xBR with a subtle bevelled, three-dimensional look to each pixel."
        case .scale3x: return "EPX/Scale3x: rounds off staircase edges and keeps the original colours."
        case .advInterp: return "Edge-aware interpolation, similar to hq3x; softer than xBR."
        case .catmullRom: return "Bicubic smoothing that stays sharper than bilinear."
        case .bilinear: return "Plain smoothing; blurry but free of jagged edges."
        case .crt: return "Staging's adaptive CRT emulation: scanlines and phosphors matched to each video mode."
        case .crtMachine: return "CRT emulation for the configured video card; EGA games look double-scanned on VGA."
        case .crtArcade: return "Thick scanlines and a softer image, like an arcade or home-computer monitor."
        case .crtArcadeSharp: return "Arcade-style scanlines with a PC monitor's sharpness."
        case .asConfigured: return "Leaves it to eXo's config and your own emulator defaults."
        }
    }

    /// The shader setting in DOSBox Staging 0.83.
    public var dosboxShader: String? {
        switch self {
        case .sharp: return "sharp"
        case .nearest: return "interpolation/nearest"
        case .xbr: return "scaler/xbr-lv3"
        case .xbrNoBlend: return "scaler/xbr-lv2-noblend"
        case .xbr3D: return "scaler/xbr-lv2-3d"
        case .scale3x: return "scaler/advmame3x"
        case .advInterp: return "scaler/advinterp3x"
        case .catmullRom: return "interpolation/catmull-rom"
        case .bilinear: return "interpolation/bilinear"
        case .crt: return "crt-auto"
        case .crtMachine: return "crt-auto-machine"
        case .crtArcade: return "crt-auto-arcade"
        case .crtArcadeSharp: return "crt-auto-arcade-sharp"
        case .asConfigured: return nil
        }
    }

    struct ScummVMScaler {
        let name: String
        let minFactor: Int
        let maxFactor: Int
    }

    /// ScummVM's nearest equivalent among its scalers.
    var scummvmScaler: ScummVMScaler? {
        switch self {
        case .sharp, .nearest, .catmullRom, .bilinear: return ScummVMScaler(name: "normal", minFactor: 1, maxFactor: 4)
        case .xbr, .xbrNoBlend, .xbr3D: return ScummVMScaler(name: "edge", minFactor: 2, maxFactor: 3)
        case .scale3x: return ScummVMScaler(name: "advmame", minFactor: 2, maxFactor: 4)
        case .advInterp: return ScummVMScaler(name: "hq", minFactor: 2, maxFactor: 3)
        case .crt, .crtMachine, .crtArcade, .crtArcadeSharp: return ScummVMScaler(name: "tv2x", minFactor: 2, maxFactor: 2)
        case .asConfigured: return nil
        }
    }

    /// Smoothing styles: ScummVM filters them bilinearly and fits the window.
    var filtered: Bool { self == .catmullRom || self == .bilinear || self == .crtArcade }
}

public enum AspectMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 4:3 correction for the non-square-pixel modes most DOS games used.
    case auto
    /// No correction; right for DOS ports of PAL Amiga games.
    case squarePixels
    /// Fill the window or screen, e.g. widescreen.
    case stretch

    public var id: String { rawValue }

    var dosboxValue: String {
        switch self {
        case .auto: return "auto"
        case .squarePixels: return "square-pixels"
        case .stretch: return "stretch"
        }
    }

    public var title: String {
        switch self {
        case .auto: return "4:3, as on a CRT"
        case .squarePixels: return "Square pixels"
        case .stretch: return "Stretch to fill"
        }
    }
}

public enum IntegerScaling: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, vertical, horizontal, off
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .off: return "Off (fill the window)"
        }
    }
}

public enum Deinterlacing: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, light, medium, strong, full
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ColorProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, none, ebu, p22, smpteC = "smpte-c", philips, trinitron
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .none: return "None (raw colours)"
        case .ebu: return "EBU phosphors"
        case .p22: return "P22 phosphors"
        case .smpteC: return "SMPTE-C phosphors"
        case .philips: return "Philips monitor"
        case .trinitron: return "Sony Trinitron"
        }
    }
}

public enum MonochromePalette: String, Codable, Sendable, CaseIterable, Identifiable {
    case asConfigured, amber, green, white, paperwhite
    public var id: String { rawValue }
    public var title: String { self == .asConfigured ? "As configured" : rawValue.capitalized }
}

public enum CGAPalette: String, Codable, Sendable, CaseIterable, Identifiable {
    case asConfigured, standard, dga16, tandy, tandyWarm, ibm5153
    public var id: String { rawValue }

    var dosboxValue: String? {
        switch self {
        case .asConfigured: return nil
        case .standard: return "default"
        case .dga16: return "dga16"
        case .tandy: return "tandy"
        case .tandyWarm: return "tandy-warm"
        case .ibm5153: return "ibm5153"
        }
    }

    public var title: String {
        switch self {
        case .asConfigured: return "As configured"
        case .standard: return "Canonical CGA"
        case .dga16: return "DGA16 (softer contrast)"
        case .tandy: return "Tandy monitor"
        case .tandyWarm: return "Tandy monitor, warm"
        case .ibm5153: return "IBM 5153 monitor"
        }
    }
}

public enum WindowSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "default", small, medium, large
    public var id: String { rawValue }
    public var title: String { self == .automatic ? "Automatic" : rawValue.capitalized }
}
