import Foundation

// Answers come in Markdown (see UbiChat.system). On screen: its emphasis and
// code only — a link's address is dropped, so there is nothing to follow, and
// a picture is never fetched. On the clipboard: the Markdown as written, and
// HTML made from it, so a paste into a mail or a document keeps headings,
// lists, tables and code.
enum Markdown {
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
