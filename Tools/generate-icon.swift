import AppKit
import CoreGraphics

// Steward 应用图标生成器。
//
// 构图是 `>_` 加右上角一枚四角星闪：提示符占视觉中心、完整可读，说明这是
// 命令行；星闪退到角落当修饰，说明驱动它的是 AI。层次是有意的——「一眼看出
// 是命令行」是主诉求，「有 AI 元素」是辅，所以两者不能等权。
//
// 星闪放右上角也不是随手摆的：Apple Intelligence、各家编辑器的 AI 入口都在
// 那个位置，用户不需要思考就知道是什么意思。
//
// 几个刻意的取舍：
//   · 浅色底板：Dock 里多数图标是深色，白底反而更跳；深色墨迹在白底上的
//     对比度也比反过来高。
//   · 不画信号弧：弧线能补上「远程」这层意思，但和 `>_`、星闪凑在一起后
//     32px 下三者互相挤，主诉求先糊掉。
//   · 星闪用强调色而非墨色：两个同色形状在小尺寸下会读成一坨。
//
// 用法：swift Tools/generate-icon.swift <AppIcon.appiconset 路径>

let canvas: CGFloat = 1024
let inset = canvas * 0.10                 // macOS 惯例：圆角方块约占画布 80%
let side = canvas - inset * 2
let radius = side * 0.225

let ink = CGColor(red: 0.16, green: 0.18, blue: 0.28, alpha: 1)
let accent = CGColor(red: 0.35, green: 0.36, blue: 0.96, alpha: 1)

/// 四角星闪：尖角之间用二次曲线向内收腰，是当下通用的 AI 符号。
func sparklePath(center c: CGPoint, r: CGFloat, waist: CGFloat = 0.30) -> CGPath {
    let p = CGMutablePath()
    let w = r * waist
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    p.closeSubpath()
    return p
}

func render(size: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: size / canvas, y: size / canvas)
    ctx.setAllowsAntialiasing(true)

    let body = CGRect(x: inset, y: inset, width: side, height: side)
    let plate = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState(); ctx.addPath(plate); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        CGColor(red: 0.92, green: 0.93, blue: 0.97, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // 白底图标在浅色壁纸上需要一圈边界，否则会糊进背景
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
    ctx.setLineWidth(side * 0.007)
    ctx.strokePath()

    // ── 提示符 `>_` ────────────────────────────────────────────
    // 比备选稿放大一档：32px 下这是唯一要读懂的东西，宁可挤掉留白。
    let scale: CGFloat = 1.16
    let cx = body.midX - side * 0.070
    let cy = body.midY - side * 0.025
    let lw = side * 0.072 * scale
    let aw = side * 0.082 * scale, ah = side * 0.112 * scale

    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(lw); ctx.setStrokeColor(ink)
    ctx.move(to: CGPoint(x: cx - aw, y: cy + ah))
    ctx.addLine(to: CGPoint(x: cx + aw, y: cy))
    ctx.addLine(to: CGPoint(x: cx - aw, y: cy - ah))
    ctx.strokePath()

    let cw = side * 0.150 * scale, ch = lw * 0.88
    let cur = CGRect(x: cx + aw + side * 0.048 * scale, y: cy - ah - lw / 2, width: cw, height: ch)
    ctx.addPath(CGPath(roundedRect: cur, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil))
    ctx.setFillColor(ink); ctx.fillPath()

    // ── 星闪 ────────────────────────────────────────────────────
    // 比备选稿缩小并往内收：贴边会显得要掉出去，且小尺寸下容易被圆角切掉。
    ctx.addPath(sparklePath(center: CGPoint(x: body.midX + side * 0.205,
                                            y: body.midY + side * 0.185),
                            r: side * 0.098))
    ctx.setFillColor(accent); ctx.fillPath()

    return ctx.makeImage()!
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let out = CommandLine.arguments[1]
for (name, px) in sizes {
    let url = URL(fileURLWithPath: "\(out)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(size: px), nil)
    CGImageDestinationFinalize(dest)
}
print("已生成 10 个尺寸 → \(out)")
