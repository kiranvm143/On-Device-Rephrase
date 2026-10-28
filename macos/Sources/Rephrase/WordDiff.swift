import SwiftUI

/// Word-level diff for the "Fix" view: removed words struck through in red, added words in green.
enum WordDiff {
    static func attributed(from old: String, to new: String) -> AttributedString {
        let a = tokens(old), b = tokens(new)
        // Very long texts: skip the diff and just show the result.
        guard a.count * b.count < 250_000 else { return AttributedString(new) }

        // Longest common subsequence on words (ignoring surrounding whitespace).
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].word == b[j].word ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var out = AttributedString()
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].word == b[j].word {
                out += AttributedString(b[j].raw)
                i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                var piece = AttributedString(a[i].raw)
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
                out += piece
                i += 1
            } else {
                var piece = AttributedString(b[j].raw)
                piece.foregroundColor = .green
                piece.backgroundColor = .green.opacity(0.12)
                out += piece
                j += 1
            }
        }
        return out
    }

    private struct Token { let raw: String; let word: String }

    /// Splits into words that keep their trailing whitespace, so joining raw tokens rebuilds the text.
    private static func tokens(_ s: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace {
                inSpace = true
                current.append(ch)
            } else {
                if inSpace, !current.isEmpty {
                    result.append(Token(raw: current, word: current.trimmingCharacters(in: .whitespacesAndNewlines)))
                    current = ""
                }
                inSpace = false
                current.append(ch)
            }
        }
        if !current.isEmpty {
            result.append(Token(raw: current, word: current.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }
}
