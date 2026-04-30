import Foundation

/// Wraps a user-supplied search string as an FTS5 phrase, doubling any
/// embedded double quotes per the FTS5 string-literal escape rule. Forces
/// FTS5 to treat the input as a literal token sequence so that hyphens,
/// slashes, or `name:value` shapes can't be parsed as column qualifiers
/// or boolean operators. Use for tools whose callers pass natural-language
/// strings rather than composed FTS5 boolean expressions.
func sanitizeForFTS5(_ query: String) -> String {
    let escaped = query.replacing("\"", with: "\"\"")
    return "\"\(escaped)\""
}
