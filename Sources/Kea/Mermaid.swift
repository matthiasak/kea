import AppKit
import SwiftUI

// Clean-room Mermaid parser, layout and Canvas renderer for Ubi Chat.
// Pure and deterministic: every sort breaks ties by input index, and any
// input past the size caps falls back to syntax-highlighted source.

enum Mermaid {
 enum Shape: Equatable { case rect, round, stadium, circle, diamond, hexagon, start, end }
 enum Head: Equatable { case none, arrow, cross, circle }
 enum Item: Equatable {
  case node(CGRect, Shape, lines: [String], titled: Bool)
  case edge([CGPoint], dashed: Bool, thick: Bool, head: Head, label: String?)
  case text(String, CGPoint, bold: Bool, muted: Bool)
  case note(CGRect, [String])
  case wedge(center: CGPoint, radius: CGFloat, from: Double, to: Double, color: Int)
  case swatch(CGRect, color: Int)
 }
 struct Diagram: Equatable {
  let kind: String
  let size: CGSize
  let items: [Item]
  let nodes: Int
  let edges: Int
 }

 static let maxChars = 20_000
 static let maxNodes = 150
 static let maxEdges = 300
 static let maxParticipants = 20
 static let maxSequenceRows = 200

 static func diagram(_ source: String) -> Diagram? {
  guard source.count <= maxChars else { return nil }
  let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n")
   .replacingOccurrences(of: "\r", with: "\n")
   .components(separatedBy: "\n")
  var idx = 0
  while idx < rawLines.count {
   let t = rawLines[idx].trimmingCharacters(in: .whitespaces)
   if t.isEmpty || t.hasPrefix("%%") {
    idx += 1
    continue
   }
   if t == "---" {
    idx += 1
    while idx < rawLines.count, rawLines[idx].trimmingCharacters(in: .whitespaces) != "---" {
     idx += 1
    }
    if idx < rawLines.count { idx += 1 }
    continue
   }
   break
  }
  guard idx < rawLines.count else { return nil }
  let header = rawLines[idx].trimmingCharacters(in: .whitespaces)
  let bodyLines = Array(rawLines[(idx + 1)...])
  let firstWord = header.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""

  switch firstWord {
  case "flowchart", "graph":
   let parts = header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
   let dir = parts.count > 1 ? normalizeDir(parts[1]) : "TD"
   return parseFlowchart(statements(from: bodyLines), defaultDir: dir, kind: "flowchart")
  case "sequenceDiagram":
   return parseSequence(statements(from: bodyLines))
  case "pie":
   return parsePie(header: header, lines: statements(from: bodyLines))
  case "stateDiagram", "stateDiagram-v2":
   return parseState(statements(from: bodyLines))
  case "classDiagram", "classDiagram-v2":
   return parseClass(rawLines: bodyLines)
  default:
   return nil
  }
 }

 static func highlighted(_ source: String) -> AttributedString {
  let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
   .replacingOccurrences(of: "\r", with: "\n")
   .components(separatedBy: "\n")
  var out = AttributedString()
  var coloredHeader = false
  for (i, line) in lines.enumerated() {
   let trimmed = line.trimmingCharacters(in: .whitespaces)
   var attr = AttributedString(line + (i + 1 < lines.count ? "\n" : ""))
   if trimmed.hasPrefix("%%") {
    attr.foregroundColor = Palette.faint
   } else if !coloredHeader && !trimmed.isEmpty && trimmed != "---" {
    attr.foregroundColor = Palette.sunset
    attr.font = .system(size: 12, weight: .semibold, design: .monospaced)
    coloredHeader = true
   } else {
    attr.foregroundColor = Palette.ink
   }
   out.append(attr)
  }
  return out
 }

 // MARK: - Statement & Label Helpers

 private static func normalizeDir(_ raw: String) -> String {
  let u = raw.uppercased()
  switch u {
  case "TD", "TB": return "TD"
  case "BT", "LR", "RL": return u
  default: return "TD"
  }
 }

 private static func statements(from lines: [String]) -> [String] {
  var out: [String] = []
  for raw in lines {
   let t = raw.trimmingCharacters(in: .whitespaces)
   if t.isEmpty || t.hasPrefix("%%") { continue }
   var current = ""
   var depth = 0
   var inQuotes = false
   for ch in t {
    if ch == "\"" {
     inQuotes.toggle()
     current.append(ch)
    } else if !inQuotes {
     if ch == "[" || ch == "(" || ch == "{" {
      depth += 1
      current.append(ch)
     } else if ch == "]" || ch == ")" || ch == "}" {
      depth = max(0, depth - 1)
      current.append(ch)
     } else if ch == ";" && depth == 0 {
      let s = current.trimmingCharacters(in: .whitespaces)
      if !s.isEmpty && !s.hasPrefix("%%") { out.append(s) }
      current = ""
     } else {
      current.append(ch)
     }
    } else {
     current.append(ch)
    }
   }
   let s = current.trimmingCharacters(in: .whitespaces)
   if !s.isEmpty && !s.hasPrefix("%%") { out.append(s) }
  }
  return out
 }

 private static func cleanLabel(_ raw: String) -> [String] {
  var s = raw.trimmingCharacters(in: .whitespaces)
  if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
   s = String(s.dropFirst().dropLast())
  }
  for br in ["<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>"] {
   s = s.replacingOccurrences(of: br, with: "\n")
  }
  s = s.replacingOccurrences(of: "&amp;", with: "&")
   .replacingOccurrences(of: "&lt;", with: "<")
   .replacingOccurrences(of: "&gt;", with: ">")
   .replacingOccurrences(of: "&quot;", with: "\"")
   .replacingOccurrences(of: "#quot;", with: "\"")
  var wrapped: [String] = []
  for paragraph in s.components(separatedBy: "\n") {
   let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
   guard !words.isEmpty else {
    wrapped.append("")
    continue
   }
   var line = words[0]
   for word in words.dropFirst() {
    let candidate = line + " " + word
    if textWidth(candidate, bold: false) <= 180 {
     line = candidate
    } else {
     wrapped.append(line)
     line = word
    }
   }
   wrapped.append(line)
  }
  return wrapped.isEmpty ? [""] : wrapped
 }

 private static func textWidth(_ text: String, bold: Bool, size: CGFloat = 12) -> CGFloat {
  let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
  let w = NSAttributedString(string: text, attributes: [.font: font]).size().width
  return ceil(w)
 }

 // MARK: - Graph Model & Layout

 private struct NodeSpec {
  let id: String
  var lines: [String]
  var shape: Shape
  var titled: Bool
  var explicit: Bool
 }

 private struct EdgeSpec {
  let from: Int
  let to: Int
  let dashed: Bool
  let thick: Bool
  let head: Head
  let label: String?
 }

 private static func parseFlowchart(_ stmts: [String], defaultDir: String, kind: String) -> Diagram?
 {
  var dir = defaultDir
  var nodes: [NodeSpec] = []
  var nodeIndex: [String: Int] = [:]
  var edges: [EdgeSpec] = []

  func ensureNode(id: String, lines: [String]?, shape: Shape?) -> Int? {
   if let existing = nodeIndex[id] {
    if !nodes[existing].explicit, let lines, let shape {
     nodes[existing].lines = lines
     nodes[existing].shape = shape
     nodes[existing].explicit = true
    }
    return existing
   }
   guard nodes.count < maxNodes else { return nil }
   let idx = nodes.count
   nodeIndex[id] = idx
   nodes.append(
    NodeSpec(
     id: id,
     lines: lines ?? [id],
     shape: shape ?? .rect,
     titled: false,
     explicit: lines != nil
    ))
   return idx
  }

  for stmt in stmts {
   let lower = stmt.lowercased()
   if lower == "end" || lower.hasPrefix("subgraph ") || lower == "subgraph"
    || lower.hasPrefix("classdef ") || lower.hasPrefix("class ")
    || lower.hasPrefix("style ") || lower.hasPrefix("linkstyle ")
    || lower.hasPrefix("click ")
   {
    continue
   }
   if lower.hasPrefix("direction ") {
    let parts = stmt.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if parts.count > 1 { dir = normalizeDir(parts[1]) }
    continue
   }
   let chars = Array(stmt)
   var pos = 0
   guard let firstGroup = parseRefGroup(chars, &pos) else { continue }
   var leftIndices: [Int] = []
   for r in firstGroup {
    guard let ni = ensureNode(id: r.id, lines: r.lines, shape: r.shape) else { return nil }
    leftIndices.append(ni)
   }
   var guardSteps = 0
   while pos < chars.count && guardSteps < 256 {
    guardSteps += 1
    skipSpaces(chars, &pos)
    guard pos < chars.count, let op = parseOp(chars, &pos) else { break }
    skipSpaces(chars, &pos)
    guard let rightGroup = parseRefGroup(chars, &pos), !rightGroup.isEmpty else { break }
    var rightIndices: [Int] = []
    for r in rightGroup {
     guard let ni = ensureNode(id: r.id, lines: r.lines, shape: r.shape) else { return nil }
     rightIndices.append(ni)
    }
    for l in leftIndices {
     for r in rightIndices {
      guard edges.count < maxEdges else { return nil }
      edges.append(
       EdgeSpec(
        from: l, to: r,
        dashed: op.dashed, thick: op.thick, head: op.head, label: op.label
       ))
     }
    }
    leftIndices = rightIndices
   }
  }

  guard !nodes.isEmpty else { return nil }
  return layoutGraph(nodes: nodes, edges: edges, dir: dir, kind: kind)
 }

 private struct ParsedRef {
  let id: String
  let lines: [String]?
  let shape: Shape?
 }

 private struct ParsedOp {
  let dashed: Bool
  let thick: Bool
  let head: Head
  let label: String?
 }

 private static func skipSpaces(_ chars: [Character], _ pos: inout Int) {
  while pos < chars.count && chars[pos].isWhitespace { pos += 1 }
 }

 private static func isIdentChar(_ ch: Character) -> Bool {
  ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
 }

 private static func parseRefGroup(_ chars: [Character], _ pos: inout Int) -> [ParsedRef]? {
  skipSpaces(chars, &pos)
  guard let first = parseSingleRef(chars, &pos) else { return nil }
  var group = [first]
  var steps = 0
  while pos < chars.count && steps < 64 {
   steps += 1
   let saved = pos
   skipSpaces(chars, &pos)
   guard pos < chars.count, chars[pos] == "&" else {
    pos = saved
    break
   }
   pos += 1
   skipSpaces(chars, &pos)
   guard let next = parseSingleRef(chars, &pos) else {
    pos = saved
    break
   }
   group.append(next)
  }
  return group
 }

 private static func parseSingleRef(_ chars: [Character], _ pos: inout Int) -> ParsedRef? {
  skipSpaces(chars, &pos)
  let start = pos
  while pos < chars.count {
   let ch = chars[pos]
   if ch == "-" && pos + 1 < chars.count
    && (chars[pos + 1] == "-" || chars[pos + 1] == "." || chars[pos + 1] == ">")
   {
    break
   }
   if ch.isLetter || ch.isNumber || ch == "_" || (ch == "-" && pos > start) {
    pos += 1
   } else {
    break
   }
  }
  guard pos > start else { return nil }
  let id = String(chars[start..<pos])
  guard pos < chars.count else { return ParsedRef(id: id, lines: nil, shape: nil) }

  let openers: [(String, [String], Shape)] = [
   ("((", ["))"], .circle),
   ("([", ["])"], .stadium),
   ("[[", ["]]"], .rect),
   ("[(", [")]"], .rect),
   ("{{", ["}}"], .hexagon),
   ("[/", ["/]", "\\]"], .rect),
   ("[\\", ["\\]", "/]"], .rect),
   ("[", ["]"], .rect),
   ("(", [")"], .round),
   ("{", ["}"], .diamond),
   (">", ["]"], .rect),
  ]

  let rem = String(chars[pos...])
  for (open, closers, shape) in openers where rem.hasPrefix(open) {
   pos += open.count
   let textStart = pos
   var inQuotes = false
   var foundEnd: Int?
   var closerLen = 0
   while pos < chars.count {
    if chars[pos] == "\"" {
     inQuotes.toggle()
     pos += 1
     continue
    }
    if !inQuotes {
     let tail = String(chars[pos...])
     if let c = closers.first(where: { tail.hasPrefix($0) }) {
      foundEnd = pos
      closerLen = c.count
      break
     }
    }
    pos += 1
   }
   let rawText: String
   if let end = foundEnd {
    rawText = String(chars[textStart..<end])
    pos = end + closerLen
   } else {
    rawText = String(chars[textStart..<chars.count])
    pos = chars.count
   }
   return ParsedRef(id: id, lines: cleanLabel(rawText), shape: shape)
  }

  return ParsedRef(id: id, lines: nil, shape: nil)
 }

 private static func parseOp(_ chars: [Character], _ pos: inout Int) -> ParsedOp? {
  skipSpaces(chars, &pos)
  let saved = pos
  guard pos < chars.count else { return nil }
  if chars[pos] == "<" { pos += 1 }
  let runStart = pos
  while pos < chars.count && (chars[pos] == "-" || chars[pos] == "=" || chars[pos] == ".") {
   pos += 1
  }
  let runLen = pos - runStart
  guard runLen >= 2 else {
   pos = saved
   return nil
  }
  let firstRun = String(chars[runStart..<pos])
  var hasArrow = false
  var head: Head = .none
  if pos < chars.count && chars[pos] == ">" {
   hasArrow = true
   head = .arrow
   pos += 1
  } else if pos < chars.count && (chars[pos] == "x" || chars[pos] == "o") {
   let nextIdx = pos + 1
   if nextIdx >= chars.count
    || (!chars[nextIdx].isLetter && !chars[nextIdx].isNumber && chars[nextIdx] != "_")
   {
    head = chars[pos] == "x" ? .cross : .circle
    pos += 1
   }
  }

  var fullRun = firstRun
  var label: String?

  // Inline label form: `-- text -->`, `== text ==>`, `-. text .->`
  if !hasArrow && head == .none && (firstRun == "--" || firstRun == "==" || firstRun == "-.")
   && pos < chars.count && chars[pos].isWhitespace
  {
   let afterFirst = pos
   let closes = ["-.->", "-->", "---", "==>", "===", ".->", "-.-"]
   var foundClose: (Int, String)?
   var scan = pos
   while scan < chars.count {
    let tail = String(chars[scan...])
    if let c = closes.first(where: { tail.hasPrefix($0) }) {
     foundClose = (scan, c)
     break
    }
    scan += 1
   }
   if let (closePos, closeToken) = foundClose {
    let raw = String(chars[afterFirst..<closePos]).trimmingCharacters(in: .whitespaces)
    if !raw.isEmpty { label = cleanLabel(raw).joined(separator: " ") }
    fullRun += closeToken
    if closeToken.hasSuffix(">") { head = .arrow }
    pos = closePos + closeToken.count
   }
  }

  // Pipe label form: `-->|label|`
  skipSpaces(chars, &pos)
  if pos < chars.count && chars[pos] == "|" {
   pos += 1
   let lStart = pos
   while pos < chars.count && chars[pos] != "|" { pos += 1 }
   let raw = String(chars[lStart..<pos]).trimmingCharacters(in: .whitespaces)
   if !raw.isEmpty { label = cleanLabel(raw).joined(separator: " ") }
   if pos < chars.count && chars[pos] == "|" { pos += 1 }
  }

  let dashed = fullRun.contains(".")
  let thick = fullRun.contains("=")
  return ParsedOp(dashed: dashed, thick: thick, head: head, label: label)
 }

 // MARK: - State Diagram Parser

 private static func parseState(_ stmts: [String]) -> Diagram? {
  var dir = "TD"
  var nodes: [NodeSpec] = []
  var nodeIndex: [String: Int] = [:]
  var edges: [EdgeSpec] = []
  var inNote = false

  func ensure(_ id: String, lines: [String]? = nil, shape: Shape? = nil) -> Int? {
   if let idx = nodeIndex[id] {
    if let lines { nodes[idx].lines = lines }
    if let shape { nodes[idx].shape = shape }
    return idx
   }
   guard nodes.count < maxNodes else { return nil }
   let idx = nodes.count
   nodeIndex[id] = idx
   nodes.append(
    NodeSpec(
     id: id,
     lines: lines ?? (shape == .start || shape == .end ? [] : [id]),
     shape: shape ?? .round,
     titled: false,
     explicit: lines != nil
    ))
   return idx
  }

  for stmt in stmts {
   let t = stmt.trimmingCharacters(in: .whitespaces)
   let lower = t.lowercased()
   if inNote {
    if lower.hasSuffix("end note") || lower == "end note" { inNote = false }
    continue
   }
   if lower.hasPrefix("note ") {
    if !lower.contains(":") { inNote = true }
    continue
   }
   if t == "}" || lower == "end" { continue }
   if lower.hasPrefix("direction ") {
    let parts = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if parts.count > 1 { dir = normalizeDir(parts[1]) }
    continue
   }
   if lower.hasPrefix("state ") {
    if lower.hasSuffix("<<choice>>") {
     let parts = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
     if parts.count >= 2 { _ = ensure(parts[1], lines: [], shape: .diamond) }
     continue
    }
    if let asRange = t.range(of: " as ", options: .caseInsensitive) {
     let desc = String(t[t.index(t.startIndex, offsetBy: 6)..<asRange.lowerBound])
     var rest = String(t[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
     if rest.hasSuffix("{") { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
     if !rest.isEmpty { _ = ensure(rest, lines: cleanLabel(desc), shape: .round) }
    }
    continue
   }
   if let arrowRange = t.range(of: "-->") {
    let leftRaw = String(t[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    let rightPart = String(t[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    let rightRaw: String
    var edgeLabel: String?
    if let colon = rightPart.firstIndex(of: ":") {
     rightRaw = String(rightPart[..<colon]).trimmingCharacters(in: .whitespaces)
     let lbl = String(rightPart[rightPart.index(after: colon)...]).trimmingCharacters(
      in: .whitespaces)
     if !lbl.isEmpty { edgeLabel = cleanLabel(lbl).joined(separator: " ") }
    } else {
     rightRaw = rightPart
    }
    guard !leftRaw.isEmpty, !rightRaw.isEmpty else { continue }
    let fromID = leftRaw == "[*]" ? "[*]start" : leftRaw
    let toID = rightRaw == "[*]" ? "[*]end" : rightRaw
    guard let u = ensure(fromID, shape: leftRaw == "[*]" ? .start : nil),
     let v = ensure(toID, shape: rightRaw == "[*]" ? .end : nil),
     edges.count < maxEdges
    else { return nil }
    edges.append(
     EdgeSpec(from: u, to: v, dashed: false, thick: false, head: .arrow, label: edgeLabel))
    continue
   }
   if let colon = t.firstIndex(of: ":") {
    let name = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
    let desc = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if !name.isEmpty && !desc.isEmpty {
     _ = ensure(name, lines: [name] + cleanLabel(desc), shape: .round)
    }
   }
  }

  guard !nodes.isEmpty else { return nil }
  return layoutGraph(nodes: nodes, edges: edges, dir: dir, kind: "state")
 }

 // MARK: - Class Diagram Parser

 private static func parseClass(rawLines: [String]) -> Diagram? {
  var dir = "TD"
  var nodes: [NodeSpec] = []
  var nodeIndex: [String: Int] = [:]
  var edges: [EdgeSpec] = []
  var activeClass: String?

  func cleanClassText(_ s: String) -> String {
   s.replacingOccurrences(of: #"~([^~]+)~"#, with: "<$1>", options: .regularExpression)
  }

  func ensureClass(_ rawName: String, title: String? = nil) -> Int? {
   let name = cleanClassText(rawName.trimmingCharacters(in: .whitespaces))
   guard !name.isEmpty else { return nil }
   if let idx = nodeIndex[name] {
    if let title { nodes[idx].lines[0] = title }
    return idx
   }
   guard nodes.count < maxNodes else { return nil }
   let idx = nodes.count
   nodeIndex[name] = idx
   nodes.append(
    NodeSpec(id: name, lines: [title ?? name], shape: .rect, titled: true, explicit: true))
   return idx
  }

  func addMember(_ cls: String, _ member: String) {
   let m = cleanClassText(member.trimmingCharacters(in: .whitespaces))
   guard !m.isEmpty, !m.hasPrefix("<<"), let idx = ensureClass(cls) else { return }
   nodes[idx].lines.append(m)
  }

  let relTokens: [(String, Bool, Bool, Head)] = [
   ("<|--", true, false, .arrow),
   ("--|>", false, false, .arrow),
   ("<|..", true, true, .arrow),
   ("..|>", false, true, .arrow),
   ("*--", true, false, .arrow),
   ("--*", false, false, .arrow),
   ("o--", true, false, .circle),
   ("--o", false, false, .circle),
   ("<--", true, false, .arrow),
   ("-->", false, false, .arrow),
   ("<..", true, true, .arrow),
   ("..>", false, true, .arrow),
   ("--", false, false, .none),
   ("..", false, true, .none),
  ]

  for line in statements(from: rawLines) {
   let t = line.trimmingCharacters(in: .whitespaces)
   let lower = t.lowercased()
   if t.isEmpty || t.hasPrefix("%%") || lower.hasPrefix("note ") || t.hasPrefix("<<") { continue }
   if let cls = activeClass {
    if t == "}" || t.hasSuffix("}") {
     let before = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
     if !before.isEmpty { addMember(cls, before) }
     activeClass = nil
    } else {
     addMember(cls, t)
    }
    continue
   }
   if lower.hasPrefix("direction ") {
    let parts = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if parts.count > 1 { dir = normalizeDir(parts[1]) }
    continue
   }
   if lower.hasPrefix("class ") {
    var rest = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    var opensBlock = false
    if rest.hasSuffix("{") {
     opensBlock = true
     rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    var label: String?
    if let brk = rest.firstIndex(of: "["), let endBrk = rest.lastIndex(of: "]"), brk < endBrk {
     let lbl = String(rest[rest.index(after: brk)..<endBrk])
     label = cleanLabel(lbl).joined(separator: " ")
     rest = String(rest[..<brk]).trimmingCharacters(in: .whitespaces)
    }
    let clsName = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? rest
    guard ensureClass(clsName, title: label) != nil else { return nil }
    if opensBlock { activeClass = clsName }
    continue
   }

   // Check relation tokens
   var matchedRel = false
   for (tok, headOnLeft, dashed, head) in relTokens {
    if let r = t.range(of: tok) {
     var leftSide = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
     var rightFull = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
     var label: String?
     if let colon = rightFull.firstIndex(of: ":") {
      let lbl = String(rightFull[rightFull.index(after: colon)...]).trimmingCharacters(
       in: .whitespaces)
      if !lbl.isEmpty { label = cleanLabel(lbl).joined(separator: " ") }
      rightFull = String(rightFull[..<colon]).trimmingCharacters(in: .whitespaces)
     }
     leftSide = stripCardinality(leftSide, trailing: true)
     let rightSide = stripCardinality(rightFull, trailing: false)
     guard !leftSide.isEmpty, !rightSide.isEmpty else { continue }
     guard let li = ensureClass(leftSide), let ri = ensureClass(rightSide), edges.count < maxEdges
     else {
      return nil
     }
     let from = headOnLeft ? ri : li
     let to = headOnLeft ? li : ri
     edges.append(
      EdgeSpec(from: from, to: to, dashed: dashed, thick: false, head: head, label: label))
     matchedRel = true
     break
    }
   }
   if matchedRel { continue }

   if let colon = t.firstIndex(of: ":") {
    let cls = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
    let member = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if !cls.isEmpty && !member.isEmpty {
     addMember(cls, member)
    }
   }
  }

  guard !nodes.isEmpty else { return nil }
  return layoutGraph(nodes: nodes, edges: edges, dir: dir, kind: "class")
 }

 private static func stripCardinality(_ s: String, trailing: Bool) -> String {
  var out = s.trimmingCharacters(in: .whitespaces)
  if trailing, out.hasSuffix("\""), let first = out.dropLast().lastIndex(of: "\"") {
   out = String(out[..<first]).trimmingCharacters(in: .whitespaces)
  } else if !trailing, out.hasPrefix("\""), let second = out.dropFirst().firstIndex(of: "\"") {
   out = String(out[out.index(after: second)...]).trimmingCharacters(in: .whitespaces)
  }
  return out
 }

 // MARK: - Graph Layout Engine

 private static func layoutGraph(nodes: [NodeSpec], edges: [EdgeSpec], dir: String, kind: String)
  -> Diagram?
 {
  let n = nodes.count
  guard n > 0 && n <= maxNodes && edges.count <= maxEdges else { return nil }

  // 1. Node sizes
  var sizes: [CGSize] = []
  for node in nodes {
   if node.shape == .start || node.shape == .end {
    sizes.append(CGSize(width: 14, height: 14))
    continue
   }
   if node.titled {
    let titleW = textWidth(node.lines.first ?? "", bold: true)
    let memberW = node.lines.dropFirst().map { textWidth($0, bold: false) }.max() ?? 0
    let memberCount = max(0, node.lines.count - 1)
    let w = max(48, max(titleW, memberW) + 20)
    let h = CGFloat(22 + 15 * memberCount + (memberCount > 0 ? 10 : 0))
    sizes.append(CGSize(width: w, height: h))
    continue
   }
   let maxW = node.lines.map { textWidth($0, bold: false) }.max() ?? 0
   var w = max(48, maxW + 24)
   var h = max(36, CGFloat(16 * max(1, node.lines.count) + 16))
   switch node.shape {
   case .circle:
    let d = max(w, h)
    w = d
    h = d
   case .diamond:
    w += 28
    h += 20
   case .hexagon:
    w += 20
   default:
    break
   }
   sizes.append(CGSize(width: w, height: h))
  }

  // 2. Back edges via DFS in appearance order
  var adj: [[(edgeIdx: Int, to: Int)]] = Array(repeating: [], count: n)
  for (ei, e) in edges.enumerated() where e.from != e.to {
   adj[e.from].append((ei, e.to))
  }
  var state = Array(repeating: 0, count: n)  // 0 unvisited, 1 on stack, 2 done
  var backEdge = Array(repeating: false, count: edges.count)

  for start in 0..<n where state[start] == 0 {
   var stack: [(u: Int, nextIdx: Int)] = [(start, 0)]
   state[start] = 1
   while let top = stack.last {
    let u = top.u
    if top.nextIdx < adj[u].count {
     let (ei, v) = adj[u][top.nextIdx]
     stack[stack.count - 1].nextIdx += 1
     if state[v] == 1 {
      backEdge[ei] = true
     } else if state[v] == 0 {
      state[v] = 1
      stack.append((v, 0))
     }
    } else {
     state[u] = 2
     stack.removeLast()
    }
   }
  }

  // 3. Ranks via longest-path in Kahn topological order
  var dagOut: [[Int]] = Array(repeating: [], count: n)
  var indeg = Array(repeating: 0, count: n)
  for (ei, e) in edges.enumerated() where e.from != e.to && !backEdge[ei] {
   dagOut[e.from].append(e.to)
   indeg[e.to] += 1
  }
  var ranks = Array(repeating: 0, count: n)
  var ready = (0..<n).filter { indeg[$0] == 0 }
  var visitedCount = 0
  while !ready.isEmpty {
   ready.sort()
   let u = ready.removeFirst()
   visitedCount += 1
   for v in dagOut[u] {
    if ranks[u] + 1 > ranks[v] { ranks[v] = ranks[u] + 1 }
    indeg[v] -= 1
    if indeg[v] == 0 { ready.append(v) }
   }
  }
  if visitedCount < n {
   for u in 0..<n where indeg[u] > 0 { ranks[u] = 0 }
  }

  let maxRank = ranks.max() ?? 0
  var layers: [[Int]] = Array(repeating: [], count: maxRank + 1)
  for u in 0..<n {
   layers[ranks[u]].append(u)
  }

  // 4. Order within rank: 4 barycenter sweeps (down, up, down, up)
  for sweep in 0..<4 {
   let downward = sweep % 2 == 0
   let range: [Int] = downward ? Array(1...max(1, maxRank)) : Array((0..<maxRank).reversed())
   guard maxRank >= 1 else { break }
   for r in range where r >= 0 && r <= maxRank {
    let prevRank = downward ? r - 1 : r + 1
    guard prevRank >= 0 && prevRank <= maxRank else { continue }
    var posInPrev: [Int: Int] = [:]
    for (pIdx, nodeID) in layers[prevRank].enumerated() {
     posInPrev[nodeID] = pIdx
    }
    let currentLayer = layers[r]
    var scored: [(node: Int, avg: Double, curPos: Int)] = []
    for (curPos, u) in currentLayer.enumerated() {
     var neighbors: [Int] = []
     for (ei, e) in edges.enumerated() where e.from != e.to && !backEdge[ei] {
      if e.from == u, let p = posInPrev[e.to] { neighbors.append(p) }
      if e.to == u, let p = posInPrev[e.from] { neighbors.append(p) }
     }
     if neighbors.isEmpty {
      scored.append((u, Double(curPos), curPos))
     } else {
      let sum = neighbors.reduce(0, +)
      scored.append((u, Double(sum) / Double(neighbors.count), curPos))
     }
    }
    scored.sort {
     if abs($0.avg - $1.avg) > 1e-6 { return $0.avg < $1.avg }
     return $0.curPos < $1.curPos
    }
    layers[r] = scored.map(\.node)
   }
  }

  // 5. Coordinates
  let horizontal = dir == "LR" || dir == "RL"
  let reversed = dir == "BT" || dir == "RL"
  let orderedLayers = reversed ? Array(layers.reversed()) : layers
  var layerOfNode = Array(repeating: 0, count: n)
  for (li, layer) in orderedLayers.enumerated() {
   for u in layer { layerOfNode[u] = li }
  }

  let numLayers = orderedLayers.count
  var layerThickness = Array(repeating: CGFloat(0), count: numLayers)
  var layerSpan = Array(repeating: CGFloat(0), count: numLayers)
  let nodeGap: CGFloat = horizontal ? 20 : 28

  for (li, layer) in orderedLayers.enumerated() {
   if horizontal {
    layerThickness[li] = layer.map { sizes[$0].width }.max() ?? 0
    let totalH =
     layer.map { sizes[$0].height }.reduce(0, +)
     + CGFloat(max(0, layer.count - 1)) * nodeGap
    layerSpan[li] = totalH
   } else {
    layerThickness[li] = layer.map { sizes[$0].height }.max() ?? 0
    let totalW =
     layer.map { sizes[$0].width }.reduce(0, +)
     + CGFloat(max(0, layer.count - 1)) * nodeGap
    layerSpan[li] = totalW
   }
  }

  let maxSpan = layerSpan.max() ?? 0
  var gapAfter = Array(repeating: CGFloat(horizontal ? 70 : 50), count: max(0, numLayers - 1))
  for e in edges where e.from != e.to {
   guard let lbl = e.label, !lbl.isEmpty else { continue }
   let l1 = min(layerOfNode[e.from], layerOfNode[e.to])
   let l2 = max(layerOfNode[e.from], layerOfNode[e.to])
   let lw = textWidth(lbl, bold: false, size: 11)
   for g in l1..<l2 where g < gapAfter.count {
    if horizontal {
     gapAfter[g] = max(gapAfter[g], lw + 30)
    } else {
     gapAfter[g] = max(gapAfter[g], 66)
    }
   }
  }

  let margin: CGFloat = 8
  var layerStart = Array(repeating: margin, count: numLayers)
  for li in 1..<numLayers {
   layerStart[li] = layerStart[li - 1] + layerThickness[li - 1] + gapAfter[li - 1]
  }

  var rects = Array(repeating: CGRect.zero, count: n)
  for (li, layer) in orderedLayers.enumerated() {
   var cursor = margin + (maxSpan - layerSpan[li]) / 2
   for u in layer {
    let sz = sizes[u]
    if horizontal {
     let x = layerStart[li] + (layerThickness[li] - sz.width) / 2
     let y = cursor
     rects[u] = CGRect(x: x, y: y, width: sz.width, height: sz.height)
     cursor += sz.height + nodeGap
    } else {
     let x = cursor
     let y = layerStart[li] + (layerThickness[li] - sz.height) / 2
     rects[u] = CGRect(x: x, y: y, width: sz.width, height: sz.height)
     cursor += sz.width + nodeGap
    }
   }
  }

  // 6. Build Items (edges then nodes)
  var items: [Item] = []
  var maxX: CGFloat = 0
  var maxY: CGFloat = 0

  for u in 0..<n {
   maxX = max(maxX, rects[u].maxX)
   maxY = max(maxY, rects[u].maxY)
  }

  for e in edges {
   if e.from == e.to {
    let r = rects[e.from]
    let p1 = CGPoint(x: r.maxX, y: r.midY - 6)
    let p2 = CGPoint(x: r.maxX + 22, y: r.midY - 6)
    let p3 = CGPoint(x: r.maxX + 22, y: r.midY + 6)
    let p4 = CGPoint(x: r.maxX, y: r.midY + 6)
    maxX = max(maxX, r.maxX + 28)
    items.append(
     .edge([p1, p2, p3, p4], dashed: e.dashed, thick: e.thick, head: e.head, label: e.label))
   } else {
    let rFrom = rects[e.from]
    let rTo = rects[e.to]
    let cFrom = CGPoint(x: rFrom.midX, y: rFrom.midY)
    let cTo = CGPoint(x: rTo.midX, y: rTo.midY)
    let pStart = clipPoint(center: cFrom, toward: cTo, rect: rFrom, shape: nodes[e.from].shape)
    let pEnd = clipPoint(center: cTo, toward: cFrom, rect: rTo, shape: nodes[e.to].shape)
    items.append(
     .edge([pStart, pEnd], dashed: e.dashed, thick: e.thick, head: e.head, label: e.label))
   }
  }

  for u in 0..<n {
   items.append(.node(rects[u], nodes[u].shape, lines: nodes[u].lines, titled: nodes[u].titled))
  }

  let canvasSize = CGSize(width: ceil(maxX + margin), height: ceil(maxY + margin))
  return Diagram(kind: kind, size: canvasSize, items: items, nodes: n, edges: edges.count)
 }

 private static func clipPoint(center: CGPoint, toward target: CGPoint, rect: CGRect, shape: Shape)
  -> CGPoint
 {
  let dx = target.x - center.x
  let dy = target.y - center.y
  let dist = hypot(dx, dy)
  guard dist > 1e-4 else { return center }
  let hw = max(1, rect.width / 2)
  let hh = max(1, rect.height / 2)
  switch shape {
  case .circle, .start, .end:
   let r = min(hw, hh)
   return CGPoint(x: center.x + dx / dist * r, y: center.y + dy / dist * r)
  case .diamond:
   let denom = abs(dx) / hw + abs(dy) / hh
   let t = denom > 1e-5 ? 1.0 / denom : 0
   return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
  default:
   let tx = abs(dx) > 1e-5 ? hw / abs(dx) : .greatestFiniteMagnitude
   let ty = abs(dy) > 1e-5 ? hh / abs(dy) : .greatestFiniteMagnitude
   let t = min(tx, ty)
   return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
  }
 }

 // MARK: - Sequence Diagram

 private enum SeqRow {
  case message(from: Int, to: Int, text: String, dashed: Bool, head: Head)
  case note(place: String, indices: [Int], lines: [String])
  case block(text: String)
 }

 private static func parseSequence(_ stmts: [String]) -> Diagram? {
  var partIDs: [String] = []
  var partLabels: [[String]] = []
  var partLookup: [String: Int] = [:]
  var rows: [SeqRow] = []
  var autoNum: Int?

  func ensurePart(_ raw: String, label: [String]? = nil) -> Int? {
   let id = raw.trimmingCharacters(in: .whitespaces)
   guard !id.isEmpty else { return nil }
   if let idx = partLookup[id] {
    if let label { partLabels[idx] = label }
    return idx
   }
   guard partIDs.count < maxParticipants else { return nil }
   let idx = partIDs.count
   partLookup[id] = idx
   partIDs.append(id)
   partLabels.append(label ?? cleanLabel(id))
   return idx
  }

  let arrows: [(String, Bool, Head)] = [
   ("-->>", true, .arrow),
   ("->>", false, .arrow),
   ("--x", true, .cross),
   ("-x", false, .cross),
   ("--)", true, .arrow),
   ("-)", false, .arrow),
   ("-->", true, .none),
   ("->", false, .none),
  ]

  let blockWords = ["loop", "alt", "else", "opt", "par", "and", "critical", "break"]

  for stmt in stmts {
   let t = stmt.trimmingCharacters(in: .whitespaces)
   let lower = t.lowercased()
   if lower == "autonumber" {
    autoNum = 1
    continue
   }
   if lower == "end" || lower.hasPrefix("rect ") || lower.hasPrefix("activate ")
    || lower.hasPrefix("deactivate ") || lower.hasPrefix("title ")
    || lower.hasPrefix("create ") || lower.hasPrefix("destroy ")
   {
    continue
   }
   if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
    let after = t.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
    if let asRange = after.range(of: " as ", options: .caseInsensitive) {
     let id = String(after[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
     let lbl = String(after[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
     guard ensurePart(id, label: cleanLabel(lbl)) != nil else { return nil }
    } else {
     guard ensurePart(after) != nil else { return nil }
    }
    continue
   }
   if lower.hasPrefix("note ") {
    guard let colon = t.firstIndex(of: ":") else { continue }
    let headPart = String(t[t.index(t.startIndex, offsetBy: 5)..<colon]).trimmingCharacters(
     in: .whitespaces)
    let noteText = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    let hLower = headPart.lowercased()
    var place = "over"
    var whoRaw = ""
    if hLower.hasPrefix("left of ") {
     place = "left"
     whoRaw = String(headPart.dropFirst(8))
    } else if hLower.hasPrefix("right of ") {
     place = "right"
     whoRaw = String(headPart.dropFirst(9))
    } else if hLower.hasPrefix("over ") {
     place = "over"
     whoRaw = String(headPart.dropFirst(5))
    }
    let names = whoRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
     .filter { !$0.isEmpty }
    var pIndices: [Int] = []
    for nm in names {
     guard let pi = ensurePart(nm) else { return nil }
     pIndices.append(pi)
    }
    if !pIndices.isEmpty {
     guard rows.count < maxSequenceRows else { return nil }
     rows.append(.note(place: place, indices: pIndices, lines: cleanLabel(noteText)))
    }
    continue
   }
   let firstWord = lower.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
   if blockWords.contains(firstWord) {
    guard rows.count < maxSequenceRows else { return nil }
    rows.append(.block(text: t))
    continue
   }

   // Message: From ARROW To: text
   for (tok, dashed, head) in arrows {
    if let r = t.range(of: tok), let colon = t[r.upperBound...].firstIndex(of: ":") {
     let fromName = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
     var toName = String(t[r.upperBound..<colon]).trimmingCharacters(in: .whitespaces)
     if toName.hasPrefix("+") || toName.hasPrefix("-") {
      toName = String(toName.dropFirst()).trimmingCharacters(in: .whitespaces)
     }
     if toName.hasSuffix("+") || toName.hasSuffix("-") {
      toName = String(toName.dropLast()).trimmingCharacters(in: .whitespaces)
     }
     var msg = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
     if let n = autoNum {
      msg = "\(n). " + msg
      autoNum = n + 1
     }
     guard !fromName.isEmpty, !toName.isEmpty,
      let fi = ensurePart(fromName), let ti = ensurePart(toName),
      rows.count < maxSequenceRows
     else { return nil }
     rows.append(
      .message(
       from: fi, to: ti, text: cleanLabel(msg).joined(separator: " "), dashed: dashed, head: head))
     break
    }
   }
  }

  let pCount = partIDs.count
  guard pCount > 0 && pCount <= maxParticipants else { return nil }

  let boxWidths: [CGFloat] = partLabels.map { lines in
   let w = lines.map { textWidth($0, bold: false) }.max() ?? 0
   return max(w + 24, 72)
  }
  var centers = Array(repeating: CGFloat(0), count: pCount)
  centers[0] = boxWidths[0] / 2 + 8
  if pCount > 1 {
   for i in 1..<pCount {
    var maxAdjLabel: CGFloat = 0
    for row in rows {
     if case .message(let from, let to, let text, _, _) = row,
      (from == i - 1 && to == i) || (from == i && to == i - 1)
     {
      maxAdjLabel = max(maxAdjLabel, textWidth(text, bold: false, size: 11))
     }
    }
    let gap = max((boxWidths[i - 1] + boxWidths[i]) / 2 + 36, maxAdjLabel + 24)
    centers[i] = centers[i - 1] + gap
   }
  }

  var y: CGFloat = 56
  var rowItems: [Item] = []
  var msgCount = 0
  var extraRightOnLast = false

  for row in rows {
   switch row {
   case .message(let from, let to, let text, let dashed, let head):
    msgCount += 1
    if from == to {
     let cx = centers[from]
     if from == pCount - 1 { extraRightOnLast = true }
     let p1 = CGPoint(x: cx, y: y)
     let p2 = CGPoint(x: cx + 28, y: y)
     let p3 = CGPoint(x: cx + 28, y: y + 20)
     let p4 = CGPoint(x: cx, y: y + 20)
     rowItems.append(.edge([p1, p2, p3, p4], dashed: dashed, thick: false, head: head, label: nil))
     if !text.isEmpty {
      rowItems.append(
       .text(
        text, CGPoint(x: cx + 14 + textWidth(text, bold: false, size: 11) / 2, y: y - 8),
        bold: false, muted: true))
     }
     y += 44
    } else {
     let x1 = centers[from]
     let x2 = centers[to]
     let lineY = y + 12
     rowItems.append(
      .edge(
       [CGPoint(x: x1, y: lineY), CGPoint(x: x2, y: lineY)], dashed: dashed, thick: false,
       head: head, label: nil))
     if !text.isEmpty {
      rowItems.append(
       .text(text, CGPoint(x: (x1 + x2) / 2, y: lineY - 8), bold: false, muted: true))
     }
     y += 34
    }
   case .note(let place, let indices, let lines):
    let nh = CGFloat(16 * max(1, lines.count) + 16)
    let nw = max(80, (lines.map { textWidth($0, bold: false) }.max() ?? 0) + 20)
    let minIdx = indices.min() ?? 0
    let maxIdx = indices.max() ?? 0
    let nx: CGFloat
    if place == "left" {
     nx = max(4, centers[minIdx] - boxWidths[minIdx] / 2 - nw - 8)
    } else if place == "right" {
     nx = centers[maxIdx] + boxWidths[maxIdx] / 2 + 8
     if maxIdx == pCount - 1 { extraRightOnLast = true }
    } else {
     let spanMin = centers[minIdx] - boxWidths[minIdx] / 2
     let spanMax = centers[maxIdx] + boxWidths[maxIdx] / 2
     let w = max(nw, spanMax - spanMin)
     nx = (spanMin + spanMax - w) / 2
    }
    let finalW =
     place == "over"
     ? max(
      nw, (centers[maxIdx] + boxWidths[maxIdx] / 2) - (centers[minIdx] - boxWidths[minIdx] / 2))
     : nw
    rowItems.append(.note(CGRect(x: nx, y: y, width: finalW, height: nh), lines))
    y += nh + 8
   case .block(let text):
    let w = textWidth(text, bold: true, size: 11)
    rowItems.append(.text(text, CGPoint(x: 8 + w / 2, y: y + 10), bold: true, muted: true))
    y += 24
   }
  }

  let lastRowY = y
  var items: [Item] = []
  for i in 0..<pCount {
   let cx = centers[i]
   items.append(
    .edge(
     [CGPoint(x: cx, y: 32), CGPoint(x: cx, y: lastRowY + 12)], dashed: true, thick: false,
     head: .none, label: nil))
  }
  for i in 0..<pCount {
   let bw = boxWidths[i]
   let rect = CGRect(x: centers[i] - bw / 2, y: 4, width: bw, height: 32)
   items.append(.node(rect, .rect, lines: partLabels[i], titled: false))
  }
  items.append(contentsOf: rowItems)

  let totalW = centers[pCount - 1] + boxWidths[pCount - 1] / 2 + 8 + (extraRightOnLast ? 40 : 0)
  let totalH = lastRowY + 20
  return Diagram(
   kind: "sequence", size: CGSize(width: ceil(totalW), height: ceil(totalH)), items: items,
   nodes: pCount, edges: msgCount)
 }

 // MARK: - Pie Chart

 private static func parsePie(header: String, lines: [String]) -> Diagram? {
  var showData = false
  var title = ""
  let headerAfter = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
  if !headerAfter.isEmpty {
   var rem = headerAfter
   if rem.lowercased().hasPrefix("showdata") {
    showData = true
    rem = String(rem.dropFirst(8)).trimmingCharacters(in: .whitespaces)
   }
   if rem.lowercased().hasPrefix("title ") {
    title = String(rem.dropFirst(6)).trimmingCharacters(in: .whitespaces)
   }
  }

  var slices: [(label: String, value: Double)] = []
  for line in lines {
   let t = line.trimmingCharacters(in: .whitespaces)
   let lower = t.lowercased()
   if lower == "showdata" {
    showData = true
    continue
   }
   if lower.hasPrefix("title ") {
    title = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    continue
   }
   guard let colon = t.lastIndex(of: ":") else { continue }
   let rawLabel = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
   let rawVal = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
   guard let val = Double(rawVal), val >= 0 else { continue }
   let lbl = cleanLabel(rawLabel).joined(separator: " ")
   guard !lbl.isEmpty, slices.count < maxNodes else { return nil }
   slices.append((lbl, val))
  }

  let sum = slices.map(\.value).reduce(0, +)
  guard !slices.isEmpty, sum > 0 else { return nil }

  let top: CGFloat = title.isEmpty ? 8 : 28
  let center = CGPoint(x: 100, y: top + 100)
  let radius: CGFloat = 90
  var items: [Item] = []

  if !title.isEmpty {
   let cleanTitle = cleanLabel(title).joined(separator: " ")
   items.append(.text(cleanTitle, CGPoint(x: 100, y: 14), bold: true, muted: false))
  }

  var angle = -Double.pi / 2
  for (i, slice) in slices.enumerated() {
   let sweep = (slice.value / sum) * (2 * Double.pi)
   items.append(
    .wedge(center: center, radius: radius, from: angle, to: angle + sweep, color: i % 8))
   angle += sweep
  }

  let rowsHeight = CGFloat(slices.count * 20)
  let legendStartY = center.y - rowsHeight / 2
  var maxLegendW: CGFloat = 0

  for (i, slice) in slices.enumerated() {
   let pct = Int((slice.value / sum * 100).rounded())
   let valStr =
    slice.value.truncatingRemainder(dividingBy: 1) == 0
    ? "\(Int(slice.value))" : String(format: "%.1f", slice.value)
   let text = showData ? "\(slice.label)  \(valStr) (\(pct)%)" : "\(slice.label)  \(pct)%"
   let tw = textWidth(text, bold: false)
   maxLegendW = max(maxLegendW, tw)
   let rowY = legendStartY + CGFloat(i * 20)
   items.append(.swatch(CGRect(x: 216, y: rowY + 5, width: 10, height: 10), color: i % 8))
   items.append(.text(text, CGPoint(x: 232 + tw / 2, y: rowY + 10), bold: false, muted: false))
  }

  let totalW = 216 + maxLegendW + 22
  let totalH = max(200, rowsHeight) + top + 8
  return Diagram(
   kind: "pie", size: CGSize(width: ceil(totalW), height: ceil(totalH)), items: items,
   nodes: slices.count, edges: 0)
 }
}

struct DiagramView: View {
 let diagram: Mermaid.Diagram
 var zoom: CGFloat = 1

 private static let palette: [Color] = [
  Palette.sunset, Palette.feather, .blue, .orange, .purple, .teal, .pink, .gray,
 ]

 var body: some View {
  Canvas { ctx, _ in
   ctx.scaleBy(x: zoom, y: zoom)
   for item in diagram.items {
    draw(item, in: &ctx)
   }
  }
  .frame(width: diagram.size.width * zoom, height: diagram.size.height * zoom)
 }

 private func draw(_ item: Mermaid.Item, in ctx: inout GraphicsContext) {
  switch item {
  case .node(let rect, let shape, let lines, let titled):
   switch shape {
   case .start:
    let path = Path(ellipseIn: rect)
    ctx.fill(path, with: .color(Palette.ink))
    return
   case .end:
    let outer = Path(ellipseIn: rect)
    ctx.stroke(outer, with: .color(Palette.ink), lineWidth: 1.4)
    let inner = Path(ellipseIn: rect.insetBy(dx: 3.5, dy: 3.5))
    ctx.fill(inner, with: .color(Palette.ink))
    return
   default:
    let path = shapePath(rect: rect, shape: shape)
    ctx.fill(path, with: .color(Palette.wash))
    ctx.stroke(path, with: .color(Palette.faint), lineWidth: 1)
   }
   guard !lines.isEmpty else { return }
   if titled {
    let titleText = ctx.resolve(
     Text(verbatim: lines[0]).font(.system(size: 12, weight: .semibold)).foregroundStyle(
      Palette.ink))
    ctx.draw(titleText, at: CGPoint(x: rect.midX, y: rect.minY + 12), anchor: .center)
    if lines.count > 1 {
     var rule = Path()
     rule.move(to: CGPoint(x: rect.minX, y: rect.minY + 22))
     rule.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 22))
     ctx.stroke(rule, with: .color(Palette.hairline), lineWidth: 1)
     for (i, member) in lines.dropFirst().enumerated() {
      let resolved = ctx.resolve(
       Text(verbatim: member).font(.system(size: 11.5)).foregroundStyle(Palette.ink))
      let y = rect.minY + 32 + CGFloat(i) * 15
      ctx.draw(resolved, at: CGPoint(x: rect.midX, y: y), anchor: .center)
     }
    }
   } else {
    let totalH = CGFloat(lines.count) * 16
    let startY = rect.midY - totalH / 2 + 8
    for (i, line) in lines.enumerated() where !line.isEmpty {
     let resolved = ctx.resolve(
      Text(verbatim: line).font(.system(size: 12)).foregroundStyle(Palette.ink))
     ctx.draw(resolved, at: CGPoint(x: rect.midX, y: startY + CGFloat(i) * 16), anchor: .center)
    }
   }

  case .edge(let points, let dashed, let thick, let head, let label):
   guard points.count >= 2 else { return }
   var path = Path()
   path.move(to: points[0])
   for pt in points.dropFirst() {
    path.addLine(to: pt)
   }
   let style = StrokeStyle(
    lineWidth: thick ? 2.4 : 1.2, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : [])
   ctx.stroke(path, with: .color(Palette.muted), style: style)
   let fromPt = points[points.count - 2]
   let toPt = points[points.count - 1]
   drawHead(head, from: fromPt, to: toPt, in: &ctx)
   if let label, !label.isEmpty {
    let midIdx = (points.count - 1) / 2
    let a = points[midIdx]
    let b = points[min(points.count - 1, midIdx + 1)]
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    let resolved = ctx.resolve(
     Text(verbatim: label).font(.system(size: 11)).foregroundStyle(Palette.muted))
    let sz = resolved.measure(in: CGSize(width: 300, height: 100))
    let bg = CGRect(
     x: mid.x - sz.width / 2 - 4, y: mid.y - sz.height / 2 - 2, width: sz.width + 8,
     height: sz.height + 4)
    ctx.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(Palette.ground))
    ctx.draw(resolved, at: mid, anchor: .center)
   }

  case .text(let str, let pt, let bold, let muted):
   let resolved = ctx.resolve(
    Text(verbatim: str)
     .font(.system(size: 11.5, weight: bold ? .semibold : .regular))
     .foregroundStyle(muted ? Palette.muted : Palette.ink)
   )
   ctx.draw(resolved, at: pt, anchor: .center)

  case .note(let rect, let lines):
   let path = Path(roundedRect: rect, cornerRadius: 6)
   ctx.fill(path, with: .color(Palette.sunset.opacity(0.12)))
   ctx.stroke(path, with: .color(Palette.sunset.opacity(0.5)), lineWidth: 1)
   let totalH = CGFloat(lines.count) * 16
   let startY = rect.midY - totalH / 2 + 8
   for (i, line) in lines.enumerated() {
    let resolved = ctx.resolve(
     Text(verbatim: line).font(.system(size: 11.5)).foregroundStyle(Palette.ink))
    ctx.draw(resolved, at: CGPoint(x: rect.midX, y: startY + CGFloat(i) * 16), anchor: .center)
   }

  case .wedge(let center, let radius, let from, let to, let color):
   var path = Path()
   path.move(to: center)
   path.addArc(
    center: center, radius: radius, startAngle: .radians(from), endAngle: .radians(to),
    clockwise: false)
   path.closeSubpath()
   let col = Self.palette[color % Self.palette.count]
   ctx.fill(path, with: .color(col))
   ctx.stroke(path, with: .color(Palette.ground), lineWidth: 1.5)

  case .swatch(let rect, let color):
   let col = Self.palette[color % Self.palette.count]
   ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(col))
  }
 }

 private func shapePath(rect: CGRect, shape: Mermaid.Shape) -> Path {
  switch shape {
  case .rect, .start, .end:
   return Path(roundedRect: rect, cornerRadius: 4)
  case .round:
   return Path(roundedRect: rect, cornerRadius: 8)
  case .stadium:
   return Path(roundedRect: rect, cornerRadius: rect.height / 2)
  case .circle:
   return Path(ellipseIn: rect)
  case .diamond:
   var p = Path()
   p.move(to: CGPoint(x: rect.midX, y: rect.minY))
   p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
   p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
   p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
   p.closeSubpath()
   return p
  case .hexagon:
   let inset = min(12, rect.width / 4)
   var p = Path()
   p.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
   p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
   p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
   p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
   p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
   p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
   p.closeSubpath()
   return p
  }
 }

 private func drawHead(
  _ head: Mermaid.Head, from: CGPoint, to: CGPoint, in ctx: inout GraphicsContext
 ) {
  guard head != .none else { return }
  let angle = atan2(to.y - from.y, to.x - from.x)
  switch head {
  case .none:
   break
  case .arrow:
   let len: CGFloat = 8
   let spread: CGFloat = 0.45
   var tri = Path()
   tri.move(to: to)
   tri.addLine(
    to: CGPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread)))
   tri.addLine(
    to: CGPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread)))
   tri.closeSubpath()
   ctx.fill(tri, with: .color(Palette.muted))
  case .cross:
   let r: CGFloat = 4
   var xPath = Path()
   xPath.move(to: CGPoint(x: to.x - r, y: to.y - r))
   xPath.addLine(to: CGPoint(x: to.x + r, y: to.y + r))
   xPath.move(to: CGPoint(x: to.x - r, y: to.y + r))
   xPath.addLine(to: CGPoint(x: to.x + r, y: to.y - r))
   ctx.stroke(xPath, with: .color(Palette.muted), lineWidth: 1.6)
  case .circle:
   let r: CGFloat = 3.5
   let cRect = CGRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)
   ctx.fill(Path(ellipseIn: cRect), with: .color(Palette.ground))
   ctx.stroke(Path(ellipseIn: cRect), with: .color(Palette.muted), lineWidth: 1.4)
  }
 }
}
