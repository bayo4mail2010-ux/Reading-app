extends Node
## Console demo: proves the backend loop works without any UI.
## Run this scene (F5) and read the Output panel.
## Simulates a child going through placement, then several rounds of
## practice, then prints what the parent dashboard would show.

func _ready() -> void:
	var child_id := "demo_child_1"

	print("=== 1. Placement ===")
	if PlacementSession.should_skip_placement(4):
		print("Age <= 4: skipping placement, starting at ", PlacementSession.default_start_skill())
	else:
		PlacementSession.start(child_id, 6)
		# Simulate a 6-year-old doing well on letters, then well on CVC blending.
		var scripted_results := [
			{"skill": "letter_sounds_mn", "correct": true},
			{"skill": "letter_sounds_mn", "correct": true},
			{"skill": "letter_sounds_mn", "correct": true},
			{"skill": "cvc_short_a", "correct": true},
			{"skill": "cvc_short_a", "correct": true},
			{"skill": "cvc_short_a", "correct": false},
		]
		var result := {}
		for r in scripted_results:
			result = PlacementSession.record_response(child_id, r["skill"], r["correct"], 1800)
			if result["done"]:
				break
		print("Placement result: ", result)

	print("\n=== 2. Simulated practice session ===")
	MasteryTracker.refresh_unlocks(child_id)
	# Drive 20 attempts through select_next_item -> record_attempt, biased
	# toward "correct" to demonstrate a skill reaching mastery.
	for i in range(20):
		var item := MasteryTracker.select_next_item(child_id)
		if item.is_empty():
			print("No active items available (all caught up or none unlocked).")
			break
		var correct := randf() < 0.85  # simulate a kid who's doing well
		var hint_count := 0 if correct else 1
		var latency := 1200 + randi() % 800
		var res := MasteryTracker.record_attempt(child_id, item["item_id"], correct, hint_count, latency)
		print("Attempt %d: item=%s correct=%s -> %s" % [i, item["item_id"], correct, res])

	print("\n=== 3. Parent dashboard views ===")
	print("Mastered skills: ", AttemptLog.mastered_skills(child_id))
	print("Skills needing practice: ", AttemptLog.skills_needing_practice(child_id))
	print("Tier progress: ", AttemptLog.tier_progress(child_id))
	print("Daily stats: ", AttemptLog.daily_stats(child_id))
	print("Daily rollup (today): ", AttemptLog.compute_daily_rollup(child_id, Time.get_unix_time_from_system()))
