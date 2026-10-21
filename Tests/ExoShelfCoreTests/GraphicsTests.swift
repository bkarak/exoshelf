import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct GraphicsTests {
    @Test func defaultsChangeOnlyTheUpscaler() {
        let conf = GraphicsSettings().dosboxConfig()
        #expect(conf == "[sdl]\noutput=opengl\n[render]\nshader=sharp\n")
    }

    @Test func asConfiguredWritesNothing() {
        #expect(GraphicsSettings(style: .asConfigured).dosboxConfig() == "")
        #expect(GraphicsSettings(style: .asConfigured).scummvmArguments() == ["--aspect-ratio"])
    }

    @Test func everyStyleNamesABundledShader() {
        // The shaders DOSBox Staging 0.83 ships; `crt-auto*` are built in.
        let bundled: Set<String> = [
            "sharp", "interpolation/nearest", "interpolation/bilinear", "interpolation/catmull-rom",
            "scaler/xbr-lv3", "scaler/xbr-lv2-noblend", "scaler/xbr-lv2-3d", "scaler/advmame3x", "scaler/advinterp3x",
            "crt-auto", "crt-auto-machine", "crt-auto-arcade", "crt-auto-arcade-sharp",
        ]
        for style in UpscaleStyle.allCases where style != .asConfigured {
            #expect(style.dosboxShader.map(bundled.contains) == true, "\(style)")
        }
    }

    @Test func writesEverySetting() {
        var g = GraphicsSettings(style: .xbr)
        g.aspect = .squarePixels
        g.integerScaling = .vertical
        g.dedithering = 60
        g.deinterlacing = .strong
        g.colorProfile = .trinitron
        g.monochromePalette = .green
        g.cgaPalette = .tandyWarm
        g.windowSize = .large
        let conf = g.dosboxConfig()
        for line in ["[sdl]", "output=opengl", "window_size=large", "[render]", "shader=scaler/xbr-lv3",
                     "aspect=square-pixels", "integer_scaling=vertical", "dedithering=60", "deinterlacing=strong",
                     "crt_color_profile=trinitron", "monochrome_palette=green", "cga_colors=tandy-warm"] {
            #expect(conf.components(separatedBy: "\n").contains(line), "\(line)")
        }
        g.dedithering = 100
        #expect(g.dosboxConfig().contains("dedithering=on\n"))
    }

    @Test func removesTheKeysThatWouldWin() {
        let conf = "[sdl]\nwindowresolution=1280x960\noutput=openglnb\nfullscreen=false\n[render]\nglshader = sharp\naspect=true\n[autoexec]\nset output=1\nglshader=x\n"
        var g = GraphicsSettings(style: .xbr)
        g.windowSize = .large
        let out = ConfPatcher.removing(g.supersededKeys, from: conf)
        #expect(!out.contains("windowresolution") && !out.contains("output=openglnb") && !out.contains("glshader = sharp"))
        #expect(out.contains("fullscreen=false") && out.contains("aspect=true"))
        // Autoexec lines are DOS commands, whatever they look like.
        #expect(out.contains("[autoexec]\nset output=1\nglshader=x"))
        #expect(ConfPatcher.removing(GraphicsSettings(style: .asConfigured).supersededKeys, from: conf) == conf)
    }

    @Test func mapsStylesToScummVMScalers() {
        #expect(GraphicsSettings().scummvmArguments() == ["--aspect-ratio", "--scaler=normal", "--scale-factor=3", "--no-filtering", "--stretch-mode=pixel-perfect"])
        #expect(GraphicsSettings(style: .xbr).scummvmArguments().contains("--scaler=edge"))
        #expect(GraphicsSettings(style: .advInterp).scummvmArguments().contains("--scaler=hq"))
        let soft = GraphicsSettings(style: .catmullRom).scummvmArguments()
        #expect(soft.contains("--filtering") && soft.contains("--stretch-mode=fit"))
    }

    @Test func capsTheScaleFactorPerScaler() {
        var g = GraphicsSettings(style: .crt)
        g.scaleFactor = 4
        #expect(g.scummvmArguments().contains("--scale-factor=2"))
        g.style = .xbr
        #expect(g.scummvmArguments().contains("--scale-factor=3"))
        g.style = .scale3x
        #expect(g.scummvmArguments().contains("--scale-factor=4"))
    }

    @Test func aspectAndStretchReachScummVM() {
        var g = GraphicsSettings()
        g.aspect = .squarePixels
        #expect(g.scummvmArguments().first == "--no-aspect-ratio")
        g.aspect = .stretch
        #expect(g.scummvmArguments().contains("--stretch-mode=stretch"))
        g.aspect = .auto
        g.integerScaling = .off
        #expect(g.scummvmArguments().contains("--stretch-mode=fit"))
    }

    @Test func oldSavesDecodeWithDefaults() throws {
        let g = try JSONDecoder().decode(GraphicsSettings.self, from: Data(#"{"style":"crt","dedithering":250}"#.utf8))
        #expect(g.style == .crt)
        #expect(g.dedithering == 100)
        #expect(g.aspect == .auto && g.scaleFactor == 3)
        let unknown = try JSONDecoder().decode(GraphicsSettings.self, from: Data(#"{"style":"future-shader"}"#.utf8))
        #expect(unknown.style == .sharp)
        let round = try JSONDecoder().decode(GraphicsSettings.self, from: JSONEncoder().encode(GraphicsSettings(style: .xbr3D)))
        #expect(round == GraphicsSettings(style: .xbr3D))
    }
}
