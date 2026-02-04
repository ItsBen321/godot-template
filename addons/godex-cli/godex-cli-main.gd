##[b]Godex CLI[/b]
##A lightweight Godot editor plugin that connects to the [i]Codex CLI[/i] so you can ask questions, insert code, and request fixes directly from the script editor.
##
##[b]Syntax[/b]
##- [b]INSERT[/b]: [code]#/ ... /#[/code]
##- [b]FIX[/b]: [code]#/ ... [/code] [i]wraps a code block[/i] [code]/#[/code]
##- [b]ASK[/b]: [code]#( ... )#[/code]
##
##[b]Examples[/b]
##[b]INSERT[/b]
##[code]#/ create a function that validates all properties /#[/code]
##
##[b]FIX[/b]
##[code]#/ improve this loop and add error handling
##func do_work():
##	# ...
##/#[/code]
##
##[b]ASK[/b]
##[code]#( explain how to structure a simple state machine )#[/code]

@tool
extends EditorPlugin

const prefix: String = "GodexCLI/"
const color_code: String = "aa2c3bff"
const INSERT: String = "INSERT"
const FIX: String = "FIX"
const ASK: String = "ASK"
const FIX_WINDOW: PackedScene = preload("uid://ci0pn3ibkldj4")

var fix_window: Window
var codex_process: Dictionary
var output_pipe: FileAccess
var error_pipe: FileAccess
var output_buffer: String
var codex_pid: int
var context: String
var prompt_timer: int
var processing: bool = false
var active_editor: CodeEdit
var active_mode: String
var fix_line_cache: Array[int]
var current_action: String
var editor_settings: Dictionary = {
	prefix + "context_dir": "res://addons/godex-cli/context"
}
var project_settings: Dictionary = {
	prefix + "session_id": "",
	prefix + "use_git": false
}


func _enable_plugin() -> void:
	print_rich("Read the documentation and see examples over on [url]https://github.com/ItsBen321/GodexCLI[/url]")


func _enter_tree() -> void:
	_display_ascii()
	_setup_settings()
	EditorInterface.get_editor_settings().settings_changed.connect(_setup_settings)
	

func _setup_settings():
	var ES := EditorInterface.get_editor_settings()
	var PS := ProjectSettings
	for setting: String in editor_settings.keys():
		if not ES.has_setting(setting):
			ES.set_setting(setting, editor_settings[setting])
		else: editor_settings[setting] = ES.get_setting(setting)
	for setting: String in project_settings.keys():
		if not PS.has_setting(setting):
			PS.set_setting(setting,project_settings[setting])
		else: project_settings[setting] = PS.get_setting(setting)
	ES.add_property_info({
		"name": prefix + "context_dir",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
		"hint_string": "Select folder with context files."
	})
	context = ("Before executing the prompt, read the file(s) at location %s for instructions. The prompt: " %
		ProjectSettings.globalize_path(editor_settings[prefix + "context_dir"]))
		

func _display_ascii():
	display_main("""[color=%s][b]
   ██████╗  ██████╗ ██████╗ ███████╗██╗  ██╗
  ██╔════╝ ██╔═══██╗██╔══██╗██╔════╝╚██╗██╔╝
  ██║  ███╗██║   ██║██║  ██║█████╗   ╚███╔╝ 
  ██║   ██║██║   ██║██║  ██║██╔══╝   ██╔██╗ 
  ╚██████╔╝╚██████╔╝██████╔╝███████╗██╔╝ ██╗
   ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝[/b][/color]""" % color_code)
   

func _process(delta: float) -> void:
	# processing insert/fix/ask command in script
	var main_edit := EditorInterface.get_script_editor().get_current_editor()
	var current_editor: CodeEdit
	if main_edit: current_editor = main_edit.get_base_editor()
	if not current_editor: return
	var current_line: int = current_editor.get_caret_line()
	var current_string: String = current_editor.get_line(current_line).strip_edges()
	if current_string.ends_with("/#"):
		if current_string.begins_with("#/") and not processing:
			send_insert(current_string)
		elif current_editor.text.contains("#/") and not processing:
			send_fix(_find_fix_lines())
	if current_string.ends_with(")#") and current_string.begins_with("#(") and not processing:
		send_ask(current_line, current_string)
	# processing codex output buffer
	if codex_process.is_empty(): return
	if not OS.is_process_running(codex_pid):
		var exit_code := OS.get_process_exit_code(codex_pid)
		codex_process.clear()
		output_pipe = null
		error_pipe = null
		processing = false
		if exit_code != OK:
			display_process("✱ Process finished with code: " + error_string(exit_code))
		return
	if output_pipe == null and error_pipe == null:
		return
	_check_output_pipe()
	_check_error_pipe()
	
	

func _find_fix_lines() -> Array[int]:
	var lines: Array[int] = []
	var in_chunk: bool = false
	var main_edit := EditorInterface.get_script_editor().get_current_editor()
	var current_editor: CodeEdit
	if main_edit: current_editor = main_edit.get_base_editor()
	if not current_editor: return []
	for current_line: int in current_editor.get_line_count():
		var current_string: String = current_editor.get_line(current_line).strip_edges()
		if current_string.begins_with("#/"):
			in_chunk = true
		if in_chunk:
			lines.append(current_line)
		if current_string.ends_with("/#"):
			break
	return lines


func _check_output_pipe():
	if codex_process.is_empty() or not OS.is_process_running(codex_pid): return
	if output_pipe == null: return
	var new_text: String = output_pipe.get_as_text()
	if new_text.is_empty(): return
	output_buffer += new_text
	var output_text: String = ""
	while true:
		var newline_position := output_buffer.find("\n")
		if newline_position == -1:
			break
		var line := output_buffer.substr(0, newline_position).strip_edges()
		output_buffer = output_buffer.substr(newline_position + 1)
		if not line.is_empty():
			_process_output(line)
	
	
func _process_output(new_text: String):
	var json := JSON.parse_string(new_text)
	if not typeof(json) == TYPE_DICTIONARY: return
	match str(json.get("type", "")):
		"thread.started":
			ProjectSettings.set_setting(prefix + "session_id", str(json.get("thread_id", "")))
			display_process("✱ starting")
		"turn.completed":
			var usage: Dictionary = json.get("usage", {})
			var input_tokens: int = int(usage.get("input_tokens", 0))
			var output_tokens: int = int(usage.get("output_tokens", 0))
			var cached_input_tokens: int = int(usage.get("cached_input_tokens", 0))
			var final_time: int = Time.get_ticks_msec() - prompt_timer
			display_process("✱ finished:\n\tcached tokens: %d\n\tinput tokens: %d\n\toutput tokens: %d\n\tprocess time: %d ms" %
				[cached_input_tokens, input_tokens, output_tokens, final_time])
		"item.completed":
			var item: Dictionary = json.get("item", {})
			match str(item.get("type", "")):
				"command_execution":
					current_action = "✎ executing"
					display_process("[color=%s]%s[/color]" % [color_code, current_action])
				"reasoning":
					current_action = "∞ reasoning"
					display_process("[color=%s]%s:[/color] %s" % [color_code, current_action, str(item.get("text", ""))])
				"web_search":
					current_action = "⌕ web search"
					display_process("[color=%s]%s:[/color] %s" % [color_code, current_action, str(item.get("query", ""))])
				"agent_message":
					var n: int = 0
					while not codex_process.is_empty() and n < 100:
						await get_tree().physics_frame
						n += 1
					match active_mode:
						INSERT:
							_insert_output(str(item.get("text", "")))
						FIX:
							_fix_output(str(item.get("text", "")))
						ASK:
							_ask_output(str(item.get("text", "")))
							
					
func _insert_output(text: String):
	var json := JSON.parse_string(text)
	if not typeof(json) == TYPE_DICTIONARY:
		display_main("[color=%s]► [/color]%s" % [color_code, str(json)])
		return	
	var line: int = _find_line()
	if line == -1: return
	active_editor.set_line(line, json.get("CODE","No code found."))
	display_main("[color=%s]► [/color]%s" % [color_code, json.get("DESCRIPTION","No description found.")])
	
	
func _fix_output(text: String):
	var json := JSON.parse_string(text)
	if not typeof(json) == TYPE_DICTIONARY:
		display_main("[color=%s]► [/color]%s" % [color_code, str(json)])
		return	
	var line: int = _find_line()
	if line == -1: return
	active_editor.remove_line_at(line)
	for l: int in fix_line_cache.size():
		fix_line_cache[l] -= 1
	var old_script: String = _get_old_script(fix_line_cache)
	var new_script: String = json.get("CODE","No code found.")
	_popup_fix_window(json.get("DESCRIPTION","No description found."), old_script, new_script)
	display_main("[color=%s]► [/color]%s" % [color_code, json.get("DESCRIPTION","No description found.")])
	

func _ask_output(text: String):
	var json := JSON.parse_string(text)
	if not typeof(json) == TYPE_DICTIONARY:
		display_main("[color=%s]► [/color]%s" % [color_code, str(json)])
		return	
	var new_script: String = json.get("CODE","No code found.")
	if not new_script.is_empty():
		_popup_ask_window(json.get("DESCRIPTION","No description found."), new_script)
	display_main("[color=%s]► [/color]%s" % [color_code, json.get("DESCRIPTION","No description found.")])
	
	
func _get_old_script(lines: Array[int]) -> String:
	var line_string_array: PackedStringArray = []		
	var script_string: String
	for l in lines:
		line_string_array.append(active_editor.get_line(l))
	script_string = "\n".join(line_string_array)
	return script_string
	
	
func _popup_fix_window(explainer: String, old_script: String, new_script: String):
	fix_window = FIX_WINDOW.instantiate()
	add_child(fix_window)
	fix_window.setup_fix(explainer, old_script, new_script)
	fix_window.confirm.connect(_fix_confirm)
	

func _popup_ask_window(explainer: String, new_script: String):
	fix_window = FIX_WINDOW.instantiate()
	add_child(fix_window)
	fix_window.setup_ask(explainer, new_script)


func _fix_confirm(new_script: String):
	fix_line_cache.reverse()
	active_editor.begin_complex_operation()
	for l: int in fix_line_cache:
		active_editor.remove_line_at(l)
	active_editor.insert_line_at(fix_line_cache[-1], new_script)
	active_editor.end_complex_operation()


func _check_error_pipe():
	if codex_process.is_empty() or not OS.is_process_running(codex_pid): return
	if error_pipe == null: return
	var new_text: String = error_pipe.get_as_text()
	if new_text.is_empty(): return
	print("error: " + new_text)


func _find_line()-> int:
	for l: int in active_editor.get_line_count():
		if active_editor.get_line(l).strip_edges().ends_with("req id: %d" % codex_pid):
			return l
	return -1


func _fetch_path() -> String:
	var current_path: String = ""
	var current_script := EditorInterface.get_script_editor().get_current_script()
	if current_script:
		current_path = current_script.resource_path
	else:
		current_path = EditorInterface.get_current_path()
	if current_path.is_empty():
		push_error("No current file path found (script or dock selection).")
		return "Path was not found."
	return current_path


func loading_animation(frame: int = 0) -> void:
	if not active_editor or not processing: return
	const speed: float = 0.1
	var loading_spinner: String = "⣾⣽⣻⢿⡿⣟⣯⣷"
	if frame >= loading_spinner.length(): frame = 0
	var new_line: String = "# %s %s | req id: %d" % [loading_spinner[frame],current_action,codex_pid]
	var line: int = _find_line()
	if line == -1: return
	active_editor.set_line(line, new_line)
	active_editor.set_line_background_color(line, Color(1.0, 0.6, 0.1, 0.05))
	await get_tree().create_timer(speed).timeout
	loading_animation(frame + 1)


func display_input(text: String):
	print_rich("\n[b]➤ %s[/b]\n\n" % text)
	
	
func display_main(text: String):
	print_rich("\n %s\n\n" % text)


func display_process(text: String):
	print_rich("[code][i]%s[/i][/code]\n\n" % text)

	
func send_insert(text: String):
	var text_input: String = text.lstrip("#/").rstrip("/#").strip_edges()
	display_input(text_input)
	var prompt_json: Dictionary = {
		"MODE": INSERT,
		"INFO": text_input,
		"DATA": {
			"SCRIPT": ProjectSettings.globalize_path(
				_fetch_path()),
			"LINE": EditorInterface.get_script_editor().get_current_editor().get_base_editor().get_caret_line()
		}
	}
	var prompt_string = context + JSON.stringify(prompt_json)
	start_session(prompt_string, INSERT)
	
	
func send_fix(lines: Array[int]):
	if lines.is_empty(): return
	var script_editor: CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	var text_input: String = script_editor.get_line(lines[0]).strip_edges().lstrip("#/").strip_edges()
	lines.remove_at(0)
	fix_line_cache = lines.duplicate()
	script_editor.set_line(lines[-1],script_editor.get_line(lines[-1]).rstrip("/#"))
	display_input(text_input)
	var prompt_json: Dictionary = {
		"MODE": FIX,
		"INFO": text_input,
		"DATA": {
			"SCRIPT": ProjectSettings.globalize_path(
				_fetch_path()),
			"LINE": lines
		}
	}
	var prompt_string = context + JSON.stringify(prompt_json)
	start_session(prompt_string, FIX)
	
	
func send_ask(current_line: int, current_string: String):
	var text_input: String = current_string.lstrip("#(").rstrip(")#").strip_edges()
	display_input(text_input)
	var prompt_json: Dictionary = {
		"MODE": ASK,
		"INFO": text_input,
		"DATA": {
			"SCRIPT": ProjectSettings.globalize_path(
				_fetch_path()),
			"LINE": EditorInterface.get_script_editor().get_current_editor().get_base_editor().get_caret_line()
		}
	}
	var prompt_string = context + JSON.stringify(prompt_json)
	start_session(prompt_string, ASK)

	
func start_session(prompt: String, mode: String):
	if processing:
		push_error("Still processing request.")
		return
	# setup codex aruments and prompt
	var process_json: PackedStringArray = [
		"/c",
		"codex",
		"--cd", ProjectSettings.globalize_path("res://"),
		"--sandbox",
		"read-only",
		"exec",
	]
	if not project_settings[prefix + "use_git"]:
		process_json.append("--skip-git-repo-check")
	if not project_settings[prefix + "session_id"].is_empty():
		process_json.append_array([
			"resume", project_settings[prefix + "session_id"]])
	var escaped_prompt: String = prompt.replace("\"", "\\\"")
	process_json.append_array(["--json", escaped_prompt]) 
	# setup for the process
	prompt_timer = Time.get_ticks_msec()
	processing = true
	active_editor = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	active_mode = mode
	codex_process = OS.execute_with_pipe("cmd.exe",process_json,false)
	# setup up codex pipes and validations #
	if codex_process.is_empty():
		push_error("Failed to start codex")
		return
	codex_pid = int(codex_process["pid"])
	output_pipe = codex_process["stdio"]
	error_pipe = codex_process["stderr"]
	# setup animations
	match mode:
		INSERT:
			current_action = "loading"
			var new_line: String = "# loading | req id: %d" % codex_pid
			var line: int = active_editor.get_caret_line()
			if line == -1: return
			active_editor.set_line(line, new_line)
			active_editor.set_line_background_color(line, Color(1.0, 0.6, 0.1, 0.05))
			loading_animation()
		FIX:
			current_action = "loading"
			var new_line: String = "# loading | req id: %d" % codex_pid
			var line: int = -1
			for l: int in active_editor.get_line_count():
				if active_editor.get_line(l).strip_edges().begins_with("#/"):
					line = l
					break
			if line == -1: return
			active_editor.set_line(line, new_line)
			active_editor.set_line_background_color(line, Color(1.0, 0.6, 0.1, 0.05))
			loading_animation()
		ASK:
			active_editor.remove_line_at(active_editor.get_caret_line())
