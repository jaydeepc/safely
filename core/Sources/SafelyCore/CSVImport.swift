import Foundation

/// Reads the password CSV that Chrome, Safari, Edge, Brave and Firefox export.
///
/// Chrome:  name,url,username,password,note
/// Safari:  Title,URL,Username,Password,Notes,OTPAuth
/// Firefox: url,username,password,httpRealm,formActionOrigin,...
public enum PasswordCSV {
    public static func parse(_ text: String) -> [WireItem] {
        let rows = parseRows(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        func column(_ names: String...) -> Int? {
            for name in names { if let i = columns.firstIndex(of: name) { return i } }
            return nil
        }
        guard let urlCol = column("url", "website", "login_uri"),
              let userCol = column("username", "login", "login_username"),
              let passCol = column("password", "login_password") else { return [] }
        let titleCol = column("name", "title")
        let notesCol = column("note", "notes")

        return rows.dropFirst().compactMap { row in
            func field(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            let password = field(passCol)
            let url = field(urlCol)
            guard !password.isEmpty, !url.isEmpty else { return nil }
            let notes = field(notesCol)
            return WireItem(title: field(titleCol), url: url, username: field(userCol), password: password,
                            notes: notes.isEmpty ? nil : notes)
        }
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)[...]
        if chars.first == "\u{FEFF}" { chars = chars.dropFirst() }

        var i = chars.startIndex
        while i < chars.endIndex {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    let next = chars.index(after: i)
                    if next < chars.endIndex, chars[next] == "\"" {
                        field.unicodeScalars.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r":
                    if c == "\r" {
                        let next = chars.index(after: i)
                        if next < chars.endIndex, chars[next] == "\n" { i = next }
                    }
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.unicodeScalars.append(c)
                }
            }
            i = chars.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
