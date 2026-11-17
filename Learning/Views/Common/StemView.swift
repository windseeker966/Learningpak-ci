import SwiftUI

/// 题面：文字（公式、代码块、行内代码、加粗、列表）放进可选中的文本框，Markdown 表格单独排成表格
struct StemView: View {
    let text: String
    var source: String = "题面"
    var style: UIFont.TextStyle = .title3
    @Environment(\.renderScale) private var renderScale

    var body: some View {
        let parts = Self.parts(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let s):
                    SelectableText(attributed: RichText.plain(s, style: style, unescape: true, scale: renderScale),
                                   source: source, onAction: nil)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows) { cell, isHeader in
                        MathText.text(cell, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                            .bold(isHeader)
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Part {
        case text(String)
        case table([String], [[String]])
    }

    /// 按行切出表格（本行以 | 开头、下一行是分隔行）；``` 代码块里的不算
    static func parts(_ s: String) -> [Part] {
        guard s.contains("|") else { return [.text(s)] }
        let lines = s.components(separatedBy: "\n")
        var out: [Part] = []
        var text: [String] = []
        func flushText() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.text(t)) }
            text = []
        }
        var inCode = false
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle() }
            if !inCode, line.hasPrefix("|"), i + 1 < lines.count, MarkdownParser.isTableSeparator(lines[i + 1]) {
                flushText()
                let header = MarkdownParser.cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(MarkdownParser.cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append(.table(header, rows))
                continue
            }
            text.append(lines[i])
            i += 1
        }
        flushText()
        return out
    }
}
