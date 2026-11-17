import SwiftUI
import UIKit

/// 可划选的文字。选中后，编辑菜单里多出「就此提问」「解释这段」。
/// SwiftUI 的 Text 只支持系统拷贝菜单，所以用 UITextView 实现。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    /// 这段文字的出处，随划选内容一起交给 AI
    var source: String = ""
    var onAction: ((SelectionAction) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = FocuslessTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        (tv as? FocuslessTextView)?.renderingScale = context.environment.renderScale
        let c = context.coordinator
        c.onAction = onAction
        c.source = source
        // 富文本来自缓存，同一内容是同一个对象；只有换了内容才重新设置、重新测量
        if c.current !== attributed {
            if c.current == nil || !attributed.isEqual(to: c.current!) {
                tv.attributedText = attributed
                c.measured = [:]
            }
            c.current = attributed
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 600)
        guard width.isFinite, width > 0 else { return nil }
        let key = Int(width.rounded())
        if let h = context.coordinator.measured[key] { return CGSize(width: width, height: h) }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let h = ceil(size.height)
        context.coordinator.measured[key] = h
        return CGSize(width: width, height: h)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        // 公式是图片附件：不当作可交互的图片（长按「拷贝图像」），长按照常选字
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            if case .textAttachment = textItem.content { return nil }
            return defaultAction
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            if case .textAttachment = textItem.content { return nil }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        var onAction: ((SelectionAction) -> Void)?
        var source = ""
        /// 当前显示的富文本，以及各宽度下测得的高度（排版很贵，测一次就记住）
        var current: NSAttributedString?
        var measured: [Int: CGFloat] = [:]

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onAction, range.length > 0 else { return nil }
            // 公式是图片附件，取文字时还原成 $…$ 交给 AI
            let attributed = textView.attributedText ?? NSAttributedString()
            let full = textView.text as NSString
            let text = RichText.plainText(attributed.attributedSubstring(from: range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // 取划选位置所在的那一段作为定位上下文（一个文本框里可能有多段）
            let paragraph = RichText.plainText(attributed.attributedSubstring(from: full.paragraphRange(for: range)))
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = SelectionQuote(text: text, source: source, paragraph: paragraph)
            let ask = UIAction(title: "就此提问", image: UIImage(systemName: "questionmark.bubble")) { _ in
                onAction(.ask(quote))
            }
            let explain = UIAction(title: "解释这段", image: UIImage(systemName: "sparkles")) { _ in
                onAction(.explain(quote))
            }
            return UIMenu(children: [ask, explain] + suggestedActions)
        }
    }
}

/// 不参与 iPad 焦点系统的文本框。讲解里文本框很多，焦点系统每次都逐个遍历会明显拖慢切换
final class FocuslessTextView: UITextView {
    override var canBecomeFocused: Bool { false }

    // 选字、长按等只给手指：Apple Pencil 在正文上是写草稿（书写手势挂在外层页面上）
    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        super.addGestureRecognizer(g)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for g in gestureRecognizers ?? [] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }

    var renderingScale: CGFloat = 0 {
        didSet {
            if renderingScale != oldValue { setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard renderingScale > 0 else { return }
        // TextKit 的文字有独立的子层，单改 UITextView 根层的密度不足以刷新它们。
        updateScale(of: layer)
    }

    private func updateScale(of layer: CALayer) {
        if layer.contentsScale != renderingScale {
            layer.contentsScale = renderingScale
            layer.setNeedsDisplay()
        }
        if layer.shouldRasterize { layer.rasterizationScale = renderingScale }
        for child in layer.sublayers ?? [] { updateScale(of: child) }
    }
}

/// 把 Markdown 行内语法（加粗、斜体、行内代码、链接）或纯文本转成 UITextView 用的富文本
enum RichText {
    /// 转换结果缓存：同样的内容只转换一次，也让 SelectableText 能用对象身份判断内容没变
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 400
        return c
    }()

    private static func cached(_ key: String, _ make: () -> NSAttributedString) -> NSAttributedString {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let value = make()
        cache.setObject(value, forKey: key as NSString)
        return value
    }

    /// scale 为显示处的像素密度（环境的 renderScale），公式图片按它渲染
    static func markdown(_ s: String, style: UIFont.TextStyle = .body, bold: Bool = false,
                         color: UIColor = .label, scale: CGFloat) -> NSAttributedString {
        cached("md|\(style.rawValue)|\(bold)|\(color.hash)|\(scale)|\(s)") {
            makeMarkdown(s, style: style, bold: bold, color: color, scale: scale)
        }
    }

    /// 把连续的标题、段落、列表、引用合成一段富文本，放进同一个文本框
    static func document(_ blocks: [MarkdownBlock], scale: CGFloat) -> NSAttributedString {
        let key = "doc|\(scale)|" + blocks.map(\.textKey).joined(separator: "\u{1}")
        return cached(key) { makeDocument(blocks, scale: scale) }
    }

    private static func makeDocument(_ blocks: [MarkdownBlock], scale: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func para(_ configure: (NSMutableParagraphStyle) -> Void) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = 10
            configure(p)
            return p
        }
        func append(_ piece: NSAttributedString, _ style: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: piece)
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
            out.append(m)
        }
        // 段落内部的换行用行分隔符，保持在同一段里
        func oneParagraph(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\u{2028}") }

        for block in blocks {
            switch block {
            case .heading(let level, let s):
                let style: UIFont.TextStyle = level <= 1 ? .title2 : level == 2 ? .title3 : .headline
                append(makeMarkdown(oneParagraph(s), style: style, bold: true, color: .label, scale: scale),
                       para { $0.paragraphSpacingBefore = level <= 2 ? 10 : 4; $0.paragraphSpacing = 6 })
            case .paragraph(let s):
                append(makeMarkdown(oneParagraph(s), style: .body, bold: false, color: .label, scale: scale), para { _ in })
            case .list(let items):
                for (i, item) in items.enumerated() {
                    let indent = CGFloat(item.level) * 20
                    let line = NSMutableAttributedString(
                        string: item.marker + "\t",
                        attributes: [.font: font(.body, bold: false), .foregroundColor: UIColor.secondaryLabel])
                    line.append(makeMarkdown(oneParagraph(item.text), style: .body, bold: false, color: .label, scale: scale))
                    append(line, para {
                        $0.firstLineHeadIndent = indent
                        $0.headIndent = indent + 24
                        $0.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                        $0.paragraphSpacing = i == items.count - 1 ? 10 : 4
                    })
                }
            case .quote(let s):
                let line = NSMutableAttributedString(
                    string: "▍", attributes: [.font: font(.body, bold: false),
                                              .foregroundColor: UIColor.tintColor.withAlphaComponent(0.5)])
                line.append(makeMarkdown(oneParagraph(s), style: .body, bold: false, color: .secondaryLabel, scale: scale))
                append(line, para { $0.headIndent = 14 })
            default:
                break
            }
        }
        return out
    }

    private static func makeMarkdown(_ s: String, style: UIFont.TextStyle, bold: Bool, color: UIColor,
                                     scale: CGFloat) -> NSAttributedString {
        let base = font(style, bold: bold)
        let out = NSMutableAttributedString()
        // 公式为基线对齐的图片附件，其余按 Markdown 行内语法（加粗等可以跨过公式）
        let parsed = MathInline.parse(s)
        for run in parsed.text.runs {
            var f = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = f.adding(.traitBold) }
                if intent.contains(.emphasized) { f = f.adding(.traitItalic) }
                if intent.contains(.code) {
                    f = .monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            if let link = run.link { attrs[.link] = link }
            for seg in MathInline.pieces(String(parsed.text[run.range].characters), parsed.maths) {
                switch seg {
                case .text(let t): out.append(NSAttributedString(string: t, attributes: attrs))
                case .math(let latex, let display):
                    out.append(mathAttachment(latex, display: display, font: base, color: color, scale: scale))
                }
            }
        }
        applyParagraph(out)
        return out
    }

    /// 题面用 unescape: true：题面基本按纯文本显示，去掉录入时照 Markdown 写的转义（\*、\$），
    /// 并显示 ``` 代码块、`行内代码`、**加粗**（见 makePlain）
    static func plain(_ s: String, style: UIFont.TextStyle = .body, color: UIColor = .label,
                      unescape: Bool = false, scale: CGFloat) -> NSAttributedString {
        cached("plain|\(style.rawValue)|\(color.hash)|\(unescape)|\(scale)|\(s)") {
            makePlain(s, style: style, color: color, unescape: unescape, scale: scale)
        }
    }

    private static func makePlain(_ s: String, style: UIFont.TextStyle, color: UIColor, unescape: Bool,
                                  scale: CGFloat) -> NSAttributedString {
        let base = font(style, bold: false)
        let out = NSMutableAttributedString()
        // 题面（unescape）支持录入时常用的几种 Markdown：``` 代码块、`行内代码`、**加粗**；其余仍按纯文本显示
        for block in unescape ? StemBlock.split(s) : [.text(s)] {
            switch block {
            case .code(let code):
                appendCodeBlock(code, to: out, base: base, color: color)
            case .text(let text):
                let start = out.length
                for segment in MathSplitter.split(text) {
                    switch segment {
                    case .text(let t):
                        if unescape {
                            out.append(stemInline(t, base: base, color: color))
                        } else {
                            out.append(NSAttributedString(string: t, attributes: [.font: base, .foregroundColor: color]))
                        }
                    case .math(let latex, let display):
                        out.append(mathAttachment(latex, display: display, font: base, color: color, scale: scale))
                    }
                }
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 4
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
            }
        }
        return out
    }

    /// 题面里按行切出 ``` 围起来的代码块；没有收尾的 ``` 一直算到结尾
    private enum StemBlock {
        case text(String)
        case code(String)

        static func split(_ s: String) -> [StemBlock] {
            guard s.contains("```") else { return [.text(s)] }
            var out: [StemBlock] = []
            var text: [Substring] = [], code: [Substring] = []
            var inCode = false
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if inCode {
                        out.append(.code(code.joined(separator: "\n")))
                        code = []
                    } else if !text.isEmpty {
                        out.append(.text(text.joined(separator: "\n")))
                        text = []
                    }
                    inCode.toggle()
                } else if inCode {
                    code.append(line)
                } else {
                    text.append(line)
                }
            }
            if inCode { out.append(.code(code.joined(separator: "\n"))) }
            if !text.isEmpty { out.append(.text(text.joined(separator: "\n"))) }
            // 代码块前后的空行由代码块自己的段距代替
            return out.compactMap { b in
                guard case .text(let t) = b else { return b }
                let trimmed = t.trimmingCharacters(in: .newlines)
                return trimmed.isEmpty ? nil : .text(trimmed)
            }
        }
    }

    private static func appendCodeBlock(_ code: String, to out: NSMutableAttributedString, base: UIFont, color: UIColor) {
        if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 6
        p.lineSpacing = 2
        let mono = UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.85, weight: .regular)
        // 代码内部的换行用行分隔符，整段共用一个段落样式
        out.append(NSAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
            .font: mono, .foregroundColor: color, .paragraphStyle: p,
            .backgroundColor: UIColor.secondarySystemFill,
        ]))
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
    }

    private static let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// 题面文字：去掉 Markdown 转义（\* → *）；同一行里配对的 `…` 用等宽字体（去掉反引号，里面的反斜杠原样保留）；
    /// 边界清楚的 **…** 加粗。Python 题面里的 x**y、**kwargs、10**4 不当成加粗
    private static func stemInline(_ s: String, base: UIFont, color: UIColor) -> NSAttributedString {
        let chars = Array(s)
        let boldFont = base.adding(.traitBold)
        let mono = UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: .regular)
        let out = NSMutableAttributedString()
        var buffer = ""
        func flush(_ font: UIFont) {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: [.font: font, .foregroundColor: color]))
            buffer = ""
        }
        /// 紧挨 ** 时说明是代码里的运算符（x**2、f(x)**2）
        func isTight(_ c: Character) -> Bool {
            (c.isASCII && (c.isLetter || c.isNumber)) || ")]}_".contains(c)
        }
        /// 从 i 开始的 ** 能否作加粗开头：前面不紧挨字母数字，后面不是空白；返回同一行里收尾 ** 的位置
        func boldClose(from i: Int) -> Int? {
            if i > 0, chars[i - 1] == "*" || chars[i - 1] == "\\" || isTight(chars[i - 1]) { return nil }
            guard i + 2 < chars.count, !chars[i + 2].isWhitespace, chars[i + 2] != "*" else { return nil }
            var j = i + 3
            while j + 1 < chars.count, chars[j] != "\n" {
                if chars[j] == "*", chars[j + 1] == "*",
                   !chars[j - 1].isWhitespace, chars[j - 1] != "*", chars[j - 1] != "\\",
                   j + 2 >= chars.count || (chars[j + 2] != "*" && !isTight(chars[j + 2])) {
                    return j
                }
                j += 1
            }
            return nil
        }
        var boldEnd: Int? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let current = boldEnd != nil ? boldFont : base
            if ch == "\\", i + 1 < chars.count {
                if !escapable.contains(chars[i + 1]) { buffer.append("\\") }
                buffer.append(chars[i + 1])
                i += 2
            } else if ch == "`", let close = chars[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" }),
                      chars[close] == "`", close > i + 1 {
                flush(current)
                buffer = String(chars[(i + 1)..<close])
                flush(mono)
                i = close + 1
            } else if ch == "*", i == boldEnd {
                flush(current)
                boldEnd = nil
                i += 2
            } else if ch == "*", boldEnd == nil, i + 1 < chars.count, chars[i + 1] == "*", let close = boldClose(from: i) {
                flush(current)
                boldEnd = close
                i += 2
            } else {
                buffer.append(ch)
                i += 1
            }
        }
        flush(boldEnd != nil ? boldFont : base)
        return out
    }

    private static func font(_ style: UIFont.TextStyle, bold: Bool) -> UIFont {
        let f = UIFont.preferredFont(forTextStyle: style)
        return bold ? f.adding(.traitBold) : f
    }

    private static func applyParagraph(_ s: NSMutableAttributedString) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
    }
}

private extension UIFont {
    func adding(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}
