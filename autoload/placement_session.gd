extends Node
## Autoload: PlacementSession
## One-time, low-stakes adaptive check run on first launch (skipped entirely
## for very young kids, who just start at the beginning of Tier 1).
## Frames as a game, not a test: ~8-12 items, ~90 seconds, ends early once
## it's confident where the child should start.

const MAX_ITEMS := 10
const SKIP_AGE_THRESHOLD := 4  # kids this age or younger skip straight to Tier 1 start

var _responses: Array = []
var _current_probe_skill: String = "letter_sounds_mn"

func should_skip_placement(age: int) -> bool:
    return age <= SKIP_AGE_THRESHOLD

## Returns the skill_id a child of `age` should start on, without running
## an adaptive check at all.
func default_start_skill() -> String:
    return "letter_sounds_mn"

func start(child_id: String, age: int) -> void:
    _responses = []
    _current_probe_skill = "letter_sounds_mn"

## Call after each placement item is answered. Returns either
## {"done": false, "next_skill": <skill_id>} to continue, or
## {"done": true, "start_skill": <skill_id>} once placement concludes.
func record_response(child_id: String, skill_id: String, correct: bool, latency_ms: int) -> Dictionary:
    _responses.append({"skill_id": skill_id, "correct": correct, "latency_ms": latency_ms})

    if _responses.size() >= MAX_ITEMS:
        return _conclude(child_id)

    # Simple adaptive branch: two probe points (letter sounds, then CVC blending).
    if _responses.size() == 3:
        var recent_correct := _responses.slice(-3).filter(func(r): return r["correct"]).size()
        if recent_correct >= 2:
            _current_probe_skill = "cvc_short_a"  # doing well on letters, probe blending
        else:
            return _conclude(child_id)  # struggling with letters, no need to probe further
        return {"done": false, "next_skill": _current_probe_skill}

    if _responses.size() >= 6 and _current_probe_skill == "cvc_short_a":
        return _conclude(child_id)

    return {"done": false, "next_skill": _current_probe_skill}

func _conclude(child_id: String) -> Dictionary:
    var start_skill := _determine_start_skill()
    _persist_result(child_id, start_skill)
    # Mark the starting skill (and anything trivially prior) active so the
    # child can begin immediately; MasteryTracker.refresh_unlocks handles the rest.
    var st := MasteryTracker.get_state(child_id, start_skill)
    if st["status"] == "not_started":
        st["status"] = "active"
    MasteryTracker.refresh_unlocks(child_id)
    return {"done": true, "start_skill": start_skill}

func _determine_start_skill() -> String:
    if _responses.is_empty():
        return "letter_sounds_mn"
    var letter_responses := _responses.filter(func(r): return r["skill_id"] == "letter_sounds_mn" or r["skill_id"] == "letter_sounds_apr")
    var cvc_responses := _responses.filter(func(r): return r["skill_id"] == "cvc_short_a")

    if cvc_responses.size() > 0:
        var cvc_correct := cvc_responses.filter(func(r): return r["correct"]).size()
        if float(cvc_correct) / cvc_responses.size() >= 0.66:
            return "sight_words_1"  # blending well, jump to Tier 2 entry
        return "cvc_short_a"  # exposed to blending but not solid yet — start there

    if letter_responses.size() > 0:
        var letter_correct := letter_responses.filter(func(r): return r["correct"]).size()
        if float(letter_correct) / letter_responses.size() < 0.5:
            return "letter_sounds_mn"  # needs to start from the beginning

    return "letter_sounds_mn"

func _persist_result(child_id: String, start_skill: String) -> void:
    var path := "user://placement_%s.json" % child_id
    var f := FileAccess.open(path, FileAccess.WRITE)
    f.store_string(JSON.stringify({
        "child_id": child_id,
        "responses": _responses,
        "resulting_start_node": start_skill,
        "completed_at": Time.get_unix_time_from_system(),
    }))
