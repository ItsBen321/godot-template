@tool
extends Window

@onready var explainer_label: RichTextLabel = %explainer_label
@onready var old_script_edit: CodeEdit = %old_script_edit
@onready var new_script_edit: CodeEdit = %new_script_edit
@onready var cancel_button: Button = %cancel_button
@onready var confirm_button: Button = %confirm_button

var active_mode: String

signal confirm


func _ready():
	confirm_button.pressed.connect(_confirm)
	cancel_button.pressed.connect(_on_close_requested)
	

func _confirm():
	confirm.emit(new_script_edit.text)
	queue_free()
	
	
func _on_close_requested() -> void:
	queue_free()
	
	
func setup_fix(explainer: String, old_script: String, new_script: String):
	active_mode = "FIX"
	explainer_label.text = explainer
	old_script_edit.text = old_script
	new_script_edit.text = new_script
	new_script_edit.call_deferred("grab_focus")
	new_script_edit.call_deferred("grab_click_focus")
	new_script_edit.call_deferred("set_caret_line", 0)
	
	
func setup_ask(explainer: String, new_script: String):
	active_mode = "ASK"
	old_script_edit.hide()
	explainer_label.reparent(old_script_edit.get_parent())
	explainer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	explainer_label.text = explainer
	new_script_edit.text = new_script
	confirm_button.hide()
	
	
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and event.shift_pressed:
			if active_mode != "FIX": return
			_confirm()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			_on_close_requested()
			get_viewport().set_input_as_handled()
