import Foundation

// Answers come in Markdown (see UbiChat.system). On screen: its emphasis and
// code only — a link's address is dropped, so there is nothing to follow, and
// a picture is never fetched. On the clipboard: the Markdown as written, and
// HTML made from it, so a paste into a mail or a document keeps headings,
// lists, tables and code.
enum Markdown {
  indirect enum Block: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [[Block]])
    case quote([Block])
    case code(language: String, text: String, closed: Bool)
    case table(header: [String], rows: [[String]])
    case rule
  }

  static func blocks(_ text: String) -> [Block] {
    let rawLines = text.components(separatedBy: "\n").map { line -> String in
      line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
    return parseBlocks(rawLines, depth: 0)
  }

  private static func parseBlocks(_ lines: [String], depth: Int) -> [Block] {
    if depth > 6 {
      let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return joined.isEmpty ? [] : [.paragraph(joined)]
    }
    var out: [Block] = []
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // 1. Fence
      if let fence = fenceOpen(trimmed) {
        let lang = fence.language
        let marker = fence.marker
        i += 1
        var body: [String] = []
        var closed = false
        while i < lines.count {
          let t = lines[i].trimmingCharacters(in: .whitespaces)
          if t.hasPrefix(marker) && t.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).isEmpty {
            closed = true
            i += 1
            break
          }
          body.append(lines[i])
          i += 1
        }
        out.append(.code(language: lang, text: body.joined(separator: "\n"), closed: closed))
        continue
      }

      // 2. Blank
      if trimmed.isEmpty {
        i += 1
        continue
      }

      // 3. Rule
      if isRule(line) {
        out.append(.rule)
        i += 1
        continue
      }

      // 4. Heading
      if let h = parseHeading(trimmed) {
        out.append(.heading(level: h.level, text: h.text))
        i += 1
        continue
      }

      // 5. Quote
      if isQuoteLine(line) {
        var qLines: [String] = []
        while i < lines.count && isQuoteLine(lines[i]) {
          qLines.append(stripQuote(lines[i]))
          i += 1
        }
        out.append(.quote(parseBlocks(qLines, depth: depth + 1)))
        continue
      }

      // 6. Table
      if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
        let header = tableCells(line)
        let cols = header.count
        i += 2
        var rows: [[String]] = []
        while i < lines.count {
          let rLine = lines[i]
          if rLine.trimmingCharacters(in: .whitespaces).isEmpty || !rLine.contains("|") {
            break
          }
          var cells = tableCells(rLine)
          if cells.count < cols {
            cells += Array(repeating: "", count: cols - cells.count)
          } else if cells.count > cols {
            cells = Array(cells.prefix(cols))
          }
          rows.append(cells)
          i += 1
        }
        if cols > 0 {
          out.append(.table(header: header, rows: rows))
          continue
        }
      }

      // 7. List item
      if let firstItem = parseListMarker(line) {
        let listIndent = firstItem.indent
        let ordered = firstItem.ordered
        let startNum = firstItem.number
        var items: [[Block]] = []

        while i < lines.count,
              let cur = parseListMarker(lines[i]),
              cur.indent <= listIndent,
              cur.ordered == ordered
        {
          let contentIndent = cur.contentIndent
          var itemLines: [String] = [cur.rest]
          i += 1
          while i < lines.count {
            let nextLine = lines[i]
            let nextTrim = nextLine.trimmingCharacters(in: .whitespaces)
            if nextTrim.isEmpty {
              var look = i + 1
              while look < lines.count && lines[look].trimmingCharacters(in: .whitespaces).isEmpty {
                look += 1
              }
              guard look < lines.count else { break }
              let peek = lines[look]
              let peekIndent = leadingIndent(peek)
              let isSibling: Bool
              if let pm = parseListMarker(peek), pm.indent <= listIndent, pm.ordered == ordered {
                isSibling = true
              } else {
                isSibling = false
              }
              if peekIndent > listIndent || isSibling {
                itemLines.append("")
                i += 1
                continue
              } else {
                break
              }
            }
            let nextIndent = leadingIndent(nextLine)
            if nextIndent > listIndent {
              itemLines.append(dedent(nextLine, by: min(nextIndent, contentIndent)))
              i += 1
              continue
            }
            if parseListMarker(nextLine) != nil || startsNonParagraphBlock(lines, at: i) {
              break
            }
            itemLines.append(nextTrim)
            i += 1
          }
          items.append(parseBlocks(itemLines, depth: depth + 1))
        }
        out.append(.list(ordered: ordered, start: startNum, items: items))
        continue
      }

      // 8. Paragraph
      var pLines: [String] = [trimmed]
      i += 1
      while i < lines.count {
        let nextTrim = lines[i].trimmingCharacters(in: .whitespaces)
        if nextTrim.isEmpty || startsNonParagraphBlock(lines, at: i) {
          break
        }
        pLines.append(nextTrim)
        i += 1
      }
      out.append(.paragraph(pLines.joined(separator: "\n")))
    }
    return out
  }

  private static func startsNonParagraphBlock(_ lines: [String], at index: Int) -> Bool {
    let line = lines[index]
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if fenceOpen(trimmed) != nil { return true }
    if isRule(line) { return true }
    if parseHeading(trimmed) != nil { return true }
    if isQuoteLine(line) { return true }
    if line.contains("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) { return true }
    if parseListMarker(line) != nil { return true }
    return false
  }

  private static func fenceOpen(_ trimmed: String) -> (marker: String, language: String)? {
    for ch: Character in ["`", "~"] {
      var count = 0
      for c in trimmed {
        if c == ch { count += 1 } else { break }
      }
      if count >= 3 {
        let marker = String(repeating: ch, count: count)
        let after = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if ch == "`" && after.contains("`") { return nil }
        let lang = after.split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        return (marker, lang)
      }
    }
    return nil
  }

  private static func isRule(_ line: String) -> Bool {
    let noSpaces = line.filter { !$0.isWhitespace }
    guard noSpaces.count >= 3, let first = noSpaces.first,
          first == "-" || first == "*" || first == "_"
    else { return false }
    return noSpaces.allSatisfy { $0 == first }
  }

  private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
    var hashes = 0
    for c in trimmed {
      if c == "#" { hashes += 1 } else { break }
    }
    guard (1...6).contains(hashes) else { return nil }
    let rest = trimmed.dropFirst(hashes)
    guard let first = rest.first, first == " " || first == "\t" else { return nil }
    var text = rest.trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("#") {
      let dropped = text.dropLast()
      if dropped.isEmpty || dropped.last?.isWhitespace == true {
        text = dropped.trimmingCharacters(in: .whitespaces)
        break
      } else if dropped.last == "#" {
        text = String(dropped)
      } else {
        break
      }
    }
    return (hashes, text)
  }

  private static func isQuoteLine(_ line: String) -> Bool {
    var spaces = 0
    for c in line {
      if c == " " {
        spaces += 1
        if spaces > 3 { return false }
      } else if c == ">" {
        return true
      } else {
        return false
      }
    }
    return false
  }

  private static func stripQuote(_ line: String) -> String {
    guard let idx = line.firstIndex(of: ">") else { return line }
    let after = line[line.index(after: idx)...]
    if after.first == " " {
      return String(after.dropFirst())
    }
    return String(after)
  }

  private static func isTableDelimiter(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("|"), t.contains("-") else { return false }
    return t.allSatisfy { $0 == "|" || $0 == ":" || $0 == "-" || $0 == " " }
  }

  private static func tableCells(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func leadingIndent(_ line: String) -> Int {
    var cols = 0
    for c in line {
      if c == " " { cols += 1 }
      else if c == "\t" { cols += 4 }
      else { break }
    }
    return cols
  }

  private static func dedent(_ line: String, by amount: Int) -> String {
    var left = amount
    var idx = line.startIndex
    while idx < line.endIndex && left > 0 {
      if line[idx] == " " {
        left -= 1
        idx = line.index(after: idx)
      } else if line[idx] == "\t" {
        left = max(0, left - 4)
        idx = line.index(after: idx)
      } else {
        break
      }
    }
    return String(line[idx...])
  }

  private struct ListMarker {
    let indent: Int
    let ordered: Bool
    let number: Int
    let contentIndent: Int
    let rest: String
  }

  private static func parseListMarker(_ line: String) -> ListMarker? {
    if isRule(line) { return nil }
    var indent = 0
    var idx = line.startIndex
    while idx < line.endIndex {
      if line[idx] == " " {
        indent += 1
        idx = line.index(after: idx)
      } else if line[idx] == "\t" {
        indent += 4
        idx = line.index(after: idx)
      } else {
        break
      }
    }
    guard idx < line.endIndex else { return nil }
    let ch = line[idx]
    var ordered = false
    var number = 1
    var markerLen = 0
    if ch == "-" || ch == "*" || ch == "+" {
      markerLen = 1
      idx = line.index(after: idx)
    } else if ch.isASCII && ch.isNumber {
      let numStart = idx
      var digits = 0
      while idx < line.endIndex && line[idx].isASCII && line[idx].isNumber && digits < 9 {
        digits += 1
        idx = line.index(after: idx)
      }
      guard digits >= 1, idx < line.endIndex, line[idx] == "." || line[idx] == ")" else {
        return nil
      }
      number = Int(line[numStart..<idx]) ?? 1
      ordered = true
      markerLen = digits + 1
      idx = line.index(after: idx)
    } else {
      return nil
    }
    var spaces = 0
    while idx < line.endIndex {
      if line[idx] == " " {
        spaces += 1
        idx = line.index(after: idx)
      } else if line[idx] == "\t" {
        spaces += 4
        idx = line.index(after: idx)
      } else {
        break
      }
    }
    guard spaces >= 1 else { return nil }
    let rest = String(line[idx...])
    return ListMarker(
      indent: indent,
      ordered: ordered,
      number: number,
      contentIndent: indent + markerLen + spaces,
      rest: rest
    )
  }

  static func shown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    var shown = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    let linked = shown.runs.filter { $0.link != nil }.map(\.range)
    for range in linked {
      shown[range].link = nil
    }
    return shown
  }

  static func html(_ text: String) -> String {
    var out = #"<meta charset="utf-8">"#
    var open = ""
    func close() {
      switch open {
      case "p", "ul", "ol", "table":
        out += "</\(open)>"
      default:
        break
      }
      open = ""
    }
    // ponytail: one level of list; nest when answers need it
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if open == "pre" {
        if trimmed.hasPrefix("```") {
          out += "</code></pre>"
          open = ""
        } else {
          out += escape(line) + "\n"
        }
      } else if trimmed.hasPrefix("```") {
        close()
        out += "<pre><code>"
        open = "pre"
      } else if trimmed.isEmpty {
        close()
      } else if trimmed == "---" || trimmed == "***" {
        close()
        out += "<hr>"
      } else if let groups = match(#"^(#{1,6})\s+(.+)$"#, in: trimmed) {
        let n = groups[1].count
        close()
        out += "<h\(n)>\(inline(groups[2]))</h\(n)>"
      } else if trimmed.hasPrefix("|") && open == "table" {
        out += row(trimmed, "td")
      } else if trimmed.hasPrefix("|"),
        i + 1 < lines.count,
        match(#"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#, in: lines[i + 1]) != nil
      {
        close()
        out += "<table>" + row(trimmed, "th")
        open = "table"
        i += 1
      } else if let groups = match(#"^[-*+]\s+(.+)$"#, in: trimmed) {
        if open != "ul" {
          close()
          out += "<ul>"
          open = "ul"
        }
        out += "<li>\(inline(groups[1]))</li>"
      } else if let groups = match(#"^\d+[.)]\s+(.+)$"#, in: trimmed) {
        if open != "ol" {
          close()
          out += "<ol>"
          open = "ol"
        }
        out += "<li>\(inline(groups[1]))</li>"
      } else {
        if open == "p" {
          out += "<br>"
        } else {
          close()
          out += "<p>"
          open = "p"
        }
        out += inline(trimmed)
      }
      i += 1
    }
    if open == "pre" {
      out += "</code></pre>"
    } else {
      close()
    }
    return out
  }

  private static func row(_ line: String, _ tag: String) -> String {
    var inner = line
    if inner.hasPrefix("|") { inner.removeFirst() }
    if inner.hasSuffix("|") { inner.removeLast() }
    let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    return "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func inline(_ text: String) -> String {
    var s = escape(text)
    s = replace(s, #"`([^`]+)`"#, "<code>$1</code>")
    s = replace(s, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
    s = replace(s, #"\*([^*\s][^*]*)\*"#, "<em>$1</em>")
    s = replace(s, #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#, #"<a href="$2">$1</a>"#)
    return s
  }

  private static func match(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<found.numberOfRanges).map { index in
      guard let range = Range(found.range(at: index), in: text) else { return "" }
      return String(text[range])
    }
  }

  private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    return regex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
  }
}
