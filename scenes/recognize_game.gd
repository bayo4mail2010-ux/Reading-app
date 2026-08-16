extends Control

## Minimal playable "recognize" game screen.
## Fetches an item from MasteryTracker, shows it, offers word-choice buttons,
## records the attempt, and loads the next one. No art yet - just labels/buttons.

const CHILD_ID := "test_child"  # placeholder profile id until profile picker exists
const SKILL_ID := "vocabulary_objects"

var current_item: Dictionary = {}
var start_time_ms: int = 0

@onready var prompt_label: Label = Label.new()
@onready var feedback_label: Label = Label.new()
@onready var button_container: VBoxContainer = VBoxContainer.new()

func _ready() -> void:
	# Basic layout, built in code since we have no scene tree yet.
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	prompt_label.text = ""
	prompt_label.add_theme_font_size_override("font_size", 64)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(prompt_label)

	vbox.add_child(button_container)

	feedback_label.text = ""
	feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(feedback_label)

	load_next_item()

func load_next_item() -> void:
	feedback_label.text = ""
	current_item = MasteryTracker.select_next_item(CHILD_ID)

	if current_item.is_empty():
		prompt_label.text = "No items available!"
		return

	prompt_label.text = current_item.get("content", "?")
	start_time_ms = Time.get_ticks_msec()

	build_answer_buttons()

func build_answer_buttons() -> void:
	for child in button_container.get_children():
		child.queue_free()

	var correct_word: String = current_item.get("word", "")
	var all_items: Array = SkillGraph.get_items_for_skill(current_item.get("skill_id", SKILL_ID))

	var choices: Array = [correct_word]
	var pool: Array = all_items.duplicate()
	pool.shuffle()
	for item in pool:
		if choices.size() >= 4:
			break
		var w: String = item.get("word", "")
		if w != correct_word and not choices.has(w):
			choices.append(w)

	choices.shuffle()

	for word in choices:
		var btn := Button.new()
		btn.text = word
		btn.custom_minimum_size = Vector2(200, 60)
		btn.pressed.connect(func(): _on_answer_pressed(word))
		button_container.add_child(btn)

func _on_answer_pressed(chosen_word: String) -> void:
	var correct: bool = chosen_word == current_item.get("word", "")
	var latency_ms: int = Time.get_ticks_msec() - start_time_ms

	var result := MasteryTracker.record_attempt(
		CHILD_ID, current_item.get("item_id", ""), correct, 0, latency_ms
	)

	if correct:
		feedback_label.text = "Great job! 🎉"
		Companion.add_star(CHILD_ID)
		Companion.record_correct_streak(CHILD_ID)
	else:
		feedback_label.text = "Try again next time!"
		Companion.reset_correct_streak(CHILD_ID)

	Companion.record_round_completed(CHILD_ID)

	if Companion.has_pending_reward(CHILD_ID):
		var reward = Companion.claim_next_reward(CHILD_ID)
		feedback_label.text += "\nReward unlocked: %s" % str(reward)

	await get_tree().create_timer(1.2).timeout
	load_next_item()
