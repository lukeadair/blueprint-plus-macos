import Foundation

// Pure Swift: the quote spreadsheet, a hand-written .xlsx (no library). Ported from Export.kt.

/** Each room's linear feet, in run-list order: rooms with runs plus the user's `Job.rooms` (empty ones at 0). */
func roomFeet(_ job: Job, _ ratio: Double) -> [(String, Double)] {
    let byRoom = Dictionary(grouping: job.runs) { $0.room ?? "" }
    return (job.runs.map { $0.room ?? "" } + job.rooms).distinct().sorted(by: roomOrder)
        .map { room in (room, (byRoom[room] ?? []).reduce(0) { $0 + $1.inches(ratio) } / 12) }
}

private let FIRST_ROOM_ROW = 6

/**
 * A quote sheet for `job`: one row per room (LF, $/LF, total), a default $/LF in B3 that a blank room price uses,
 * and totals. Formulas carry no cached values; `fullCalcOnLoad` makes the spreadsheet app compute them on open.
 */
func quoteXlsx(_ job: Job, _ ratio: Double) -> Data {
    let rooms = roomFeet(job, ratio)
    let last = FIRST_ROOM_ROW + rooms.count - 1
    var rows: [String] = [
        row(1, str("A1", job.name, S_BOLD)),
        row(2, str("A2", "Scale"), str("B2", job.scale)),
        row(3, str("A3", "Default $/LF"), empty("B3", S_PRICE)),
        row(5, str("A5", "Room", S_BOLD), str("B5", "Linear ft", S_BOLD), str("C5", "$/LF (blank = default)", S_BOLD), str("D5", "Total", S_BOLD)),
    ]
    for (i, (room, feet)) in rooms.enumerated() {
        let r = FIRST_ROOM_ROW + i
        rows.append(row(r, str("A\(r)", room.isEmpty ? "Unassigned" : room), num("B\(r)", feet, S_FEET), empty("C\(r)", S_PRICE),
                        formula("D\(r)", "B\(r)*IF(C\(r)=\"\",$B$3,C\(r))", S_MONEY)))
    }
    let t = last + 1
    rows.append(row(t, str("A\(t)", "Total", S_BOLD), formula("B\(t)", "SUM(B\(FIRST_ROOM_ROW):B\(last))", S_FEET_BOLD), formula("D\(t)", "SUM(D\(FIRST_ROOM_ROW):D\(last))", S_MONEY_BOLD)))
    let sheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="1" width="26" customWidth="1"/><col min="2" max="2" width="12" customWidth="1"/><col min="3" max="3" width="22" customWidth="1"/><col min="4" max="4" width="14" customWidth="1"/></cols><sheetData>\(rows.joined())</sheetData></worksheet>
    """
    var sheetName = String(job.name.filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: "' ")).prefix(31))
    if sheetName.isEmpty { sheetName = "Quote" }
    var zip = StoredZip()
    zip.put("[Content_Types].xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
    """)
    zip.put("_rels/.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """)
    zip.put("xl/workbook.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(esc(sheetName))" sheetId="1" r:id="rId1"/></sheets><calcPr fullCalcOnLoad="1"/></workbook>
    """)
    zip.put("xl/_rels/workbook.xml.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """)
    zip.put("xl/styles.xml", STYLES)
    zip.put("xl/worksheets/sheet1.xml", sheet)
    return zip.finish()
}

// Cell style indices into STYLES' cellXfs.
private let S_BOLD = 1
private let S_FEET = 2
private let S_MONEY = 3
private let S_PRICE = 4 // an input: money format on a light yellow fill
private let S_FEET_BOLD = 5
private let S_MONEY_BOLD = 6

private let STYLES = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="2" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/><xf numFmtId="2" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/></cellXfs></styleSheet>
"""

private func esc(_ s: String) -> String {
    String(String.UnicodeScalarView(s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0.value >= 0x20 })) // control characters aren't allowed in XML 1.0
}
private func row(_ r: Int, _ cells: String...) -> String { "<row r=\"\(r)\">\(cells.joined())</row>" }
private func str(_ ref: String, _ s: String, _ style: Int = 0) -> String { "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>" }
private func num(_ ref: String, _ v: Double, _ style: Int) -> String { "<c r=\"\(ref)\" s=\"\(style)\"><v>\(v)</v></c>" }
private func empty(_ ref: String, _ style: Int) -> String { "<c r=\"\(ref)\" s=\"\(style)\"/>" }
private func formula(_ ref: String, _ f: String, _ style: Int) -> String { "<c r=\"\(ref)\" s=\"\(style)\"><f>\(esc(f))</f></c>" }

/**
 * A minimal zip archive of uncompressed entries, enough for an .xlsx.
 * shortcut: stored, not deflated (a quote is a few KB); add deflate if files ever get big.
 */
struct StoredZip {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func put(_ path: String, _ text: String) {
        let name = Data(path.utf8), data = Data(text.utf8)
        let crc = crc32(data), offset = UInt32(body.count)
        var local = Data()
        local.le(UInt32(0x04034b50)); local.le(UInt16(20)); local.le(UInt16(0x0800)) // version, flags (UTF-8 names)
        local.le(UInt16(0)); local.le(UInt16(0)); local.le(UInt16(0x21)) // stored, time, date (1980-01-01)
        local.le(crc); local.le(UInt32(data.count)); local.le(UInt32(data.count))
        local.le(UInt16(name.count)); local.le(UInt16(0))
        body.append(local); body.append(name); body.append(data)
        central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0x0800))
        central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0x21))
        central.le(crc); central.le(UInt32(data.count)); central.le(UInt32(data.count))
        central.le(UInt16(name.count)); central.le(UInt16(0)); central.le(UInt16(0)) // name, extra, comment lengths
        central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(offset) // disk, attrs, offset
        central.append(name)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(central)
        out.le(UInt32(0x06054b50)); out.le(UInt16(0)); out.le(UInt16(0)); out.le(count); out.le(count)
        out.le(UInt32(central.count)); out.le(UInt32(body.count)); out.le(UInt16(0))
        return out
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

private let CRC_TABLE: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = CRC_TABLE[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}
