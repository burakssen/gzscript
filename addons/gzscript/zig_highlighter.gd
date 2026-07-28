@tool
extends EditorSyntaxHighlighter

# ponytail: flat lexical scanner; Godot does not expose CodeHighlighter composition to GDScript.

const KEYWORDS := {
	"addrspace": true, "align": true, "allowzero": true, "and": true,
	"anyframe": true, "anytype": true, "asm": true, "async": true,
	"await": true, "callconv": true, "comptime": true, "const": true,
	"defer": true, "enum": true, "errdefer": true, "error": true,
	"export": true, "extern": true, "fn": true, "inline": true,
	"linksection": true, "noalias": true, "noinline": true, "nosuspend": true,
	"opaque": true, "or": true, "orelse": true, "packed": true, "pub": true,
	"resume": true, "struct": true, "suspend": true, "test": true,
	"threadlocal": true, "union": true, "unreachable": true,
	"usingnamespace": true, "var": true, "volatile": true,
}
const CONTROL_FLOW := {
	"break": true, "catch": true, "continue": true, "else": true, "for": true,
	"if": true, "return": true, "switch": true, "try": true, "while": true,
}
const TYPES := {
	"anyerror": true, "anyopaque": true, "bool": true, "c_char": true,
	"c_int": true, "c_long": true, "c_longdouble": true, "c_longlong": true,
	"c_short": true, "c_uint": true, "c_ulong": true, "c_ulonglong": true,
	"c_ushort": true, "comptime_float": true, "comptime_int": true, "f16": true,
	"f32": true, "f64": true, "f128": true, "i8": true, "i16": true,
	"i32": true, "i64": true, "isize": true, "noreturn": true, "type": true,
	"u8": true, "u16": true, "u32": true, "u64": true, "usize": true,
	"void": true,
}
const VALUES := {"false": true, "null": true, "true": true, "undefined": true}

var keyword_color := Color.WHITE
var control_flow_color := Color.WHITE
var type_color := Color.WHITE
var comment_color := Color.GRAY
var doc_comment_color := Color.GRAY
var string_color := Color.GREEN
var number_color := Color.CYAN
var function_color := Color.YELLOW
var symbol_color := Color.WHITE
var text_color := Color.WHITE


func _get_name() -> String:
	return "Zig"


func _get_supported_languages() -> PackedStringArray:
	return PackedStringArray(["Zig"])


func _create() -> EditorSyntaxHighlighter:
	return get_script().new()


func _update_cache() -> void:
	var settings := EditorInterface.get_editor_settings()
	var path := "text_editor/theme/highlighting/"
	keyword_color = settings.get_setting(path + "keyword_color")
	control_flow_color = settings.get_setting(path + "control_flow_keyword_color")
	type_color = settings.get_setting(path + "base_type_color")
	comment_color = settings.get_setting(path + "comment_color")
	doc_comment_color = settings.get_setting(path + "doc_comment_color")
	string_color = settings.get_setting(path + "string_color")
	number_color = settings.get_setting(path + "number_color")
	function_color = settings.get_setting(path + "function_color")
	symbol_color = settings.get_setting(path + "symbol_color")
	text_color = settings.get_setting(path + "text_color")


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var text := get_text_edit().get_line(line)
	var result := {}
	var i := 0
	while i < text.length():
		var start := i
		var character := text[i]
		if character == " " or character == "\t" or character == "\r":
			i += 1
			continue
		if character == "/" and i + 1 < text.length() and text[i + 1] == "/":
			var doc_comment := text.substr(i, 3) in ["///", "//!"] and text.substr(i, 4) != "////"
			result[i] = {"color": doc_comment_color if doc_comment else comment_color}
			return result
		if character == "\\" and i + 1 < text.length() and text[i + 1] == "\\":
			result[i] = {"color": string_color}
			return result
		if character == "\"" or character == "'":
			i = _scan_quoted(text, i, character)
			_set_region(result, start, i, string_color, text.length())
			continue
		if character == "@":
			i += 1
			while i < text.length() and _is_identifier_character(text[i]):
				i += 1
			_set_region(result, start, i, function_color, text.length())
			continue
		if _is_digit(character):
			i = _scan_number(text, i)
			_set_region(result, start, i, number_color, text.length())
			continue
		if _is_identifier_start(character):
			i += 1
			while i < text.length() and _is_identifier_character(text[i]):
				i += 1
			var word := text.substr(start, i - start)
			if CONTROL_FLOW.has(word):
				_set_region(result, start, i, control_flow_color, text.length())
			elif KEYWORDS.has(word) or VALUES.has(word):
				_set_region(result, start, i, keyword_color, text.length())
			elif TYPES.has(word):
				_set_region(result, start, i, type_color, text.length())
			continue
		result[i] = {"color": symbol_color}
		i += 1
		if i < text.length():
			result[i] = {"color": text_color}
	return result


func _set_region(result: Dictionary, start: int, end: int, color: Color, length: int) -> void:
	result[start] = {"color": color}
	if end < length:
		result[end] = {"color": text_color}


func _scan_quoted(text: String, start: int, quote: String) -> int:
	var i := start + 1
	while i < text.length():
		if text[i] == "\\":
			i += 2
		elif text[i] == quote:
			return i + 1
		else:
			i += 1
	return i


func _scan_number(text: String, start: int) -> int:
	var i := start + 1
	while i < text.length():
		var character := text[i]
		if _is_identifier_character(character) or character == ".":
			i += 1
		elif (character == "+" or character == "-") and text[i - 1].to_lower() in ["e", "p"]:
			i += 1
		else:
			break
	return i


func _is_digit(character: String) -> bool:
	return character >= "0" and character <= "9"


func _is_identifier_start(character: String) -> bool:
	return character == "_" or character >= "a" and character <= "z" or character >= "A" and character <= "Z"


func _is_identifier_character(character: String) -> bool:
	return _is_identifier_start(character) or _is_digit(character)
