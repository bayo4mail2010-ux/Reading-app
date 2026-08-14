extends Node
## Autoload: MasteryTracker
## Owns per-child skill state: rolling attempt windows, mastery decisions,
## unlocking, and spaced-repetition scheduling. Persists to user:// as JSON
## (local-first; nothing leaves the device unless a sync layer is added later).

const WINDOW_SIZE := 8
const MIN_ATTEMPTS_FOR_MASTERY := 5
const MASTERY_SUCCESS_RATE := 0.8
const SPACED_INTERVALS_DAYS := [1, 3, 7, 21]  # days, index advances each successful review

# child_id -> skill_id -> state dict
# state dict shape:
# {
#   status: "not_started" | "active" | "mastered" | "decayed",
#   attempts_window: Array[bool]        (max WINDOW_SIZE, oldest first)
#   hint_window: Array[int]             (parallel to attempts_window, hint_count per attempt)
#   latency_window: Array[int]          (parallel, ms per attempt)
#   success_rate: float,
#   avg_latency_ms: float,
#   consecutive_misses: int,
#   last_seen_at: int (unix time),
#   mastered_at: int (unix time, -1 if never),
#   review_interval_index: int,
#   next_review_at: int (unix time, -1 if n/a),
#   needs_easier_modality: bool
# }
var _state: Dictionary = {}

func _default_state() -> Dictionary:
    return {
        "status": "not_started",
        "attempts_window": [],
        "hint_window": [],
        "latency_window": [],
        "success_rate": 0.0,
        "avg_latency_ms": 0.0,
        "consecutive_misses": 0,
        "last_seen_at": -1,
        "mastered_at": -1,
        "review_interval_index": 0,
        "next_review_at": -1,
        "needs_easier_modality": false,
    }

func _ensure_child(child_id: String) -> void:
    if not _state.has(child_id):
        _state[child_id] = {}
        _load_state(child_id)

func get_state(child_id: String, skill_id: String) -> Dictionary:
    _ensure_child(child_id)
    if not _state[child_id].has(skill_id):
        _state[child_id][skill_id] = _default_state()
    return _state[child_id][skill_id]

func get_status(child_id: String, skill_id: String) -> String:
    return get_state(child_id, skill_id)["status"]

## Returns skill_id -> status for every skill, for use with SkillGraph prereq checks.
func status_map(child_id: String) -> Dictionary:
    _ensure_child(child_id)
    var out := {}
    for skill_id in SkillGraph.get_all_skill_ids():
        out[skill_id] = get_status(child_id, skill_id)
    return out

## Call once at session start (or whenever a skill's hard prereqs might have
## just become satisfied) to promote eligible "not_started" skills to "active".
func refresh_unlocks(child_id: String) -> void:
    var statuses := status_map(child_id)
    for skill_id in SkillGraph.get_all_skill_ids():
        var st := get_state(child_id, skill_id)
        if st["status"] == "not_started":
            if SkillGraph.hard_prereqs_satisfied(skill_id, statuses) \
            and SkillGraph.soft_prereqs_satisfied(skill_id, statuses):
                st["status"] = "active"
## Core entry point: record the result of one attempt and update mastery state.
## Returns a result dict the UI layer can react to (mastered_now, needs_easier_modality, etc).
func record_attempt(child_id: String, item_id: String, correct: bool, hint_count: int, latency_ms: int) -> Dictionary:
    var item := SkillGraph.get_item(item_id)
    if item.is_empty():
        push_error("MasteryTracker: unknown item_id %s" % item_id)
        return {}
    var skill_id: String = item["skill_id"]
    var st := get_state(child_id, skill_id)
    var now := Time.get_unix_time_from_system()

    # Update rolling window (push newest, trim oldest).
    st["attempts_window"].append(correct)
    st["hint_window"].append(hint_count)
    st["latency_window"].append(latency_ms)
    if st["attempts_window"].size() > WINDOW_SIZE:
        st["attempts_window"].pop_front()
        st["hint_window"].pop_front()
        st["latency_window"].pop_front()

    st["last_seen_at"] = now
    st["consecutive_misses"] = 0 if correct else st["consecutive_misses"] + 1
    st["needs_easier_modality"] = st["consecutive_misses"] >= 2

    _recompute_rates(st)

    var mastered_now := false
    if st["status"] != "mastered" and _meets_mastery(st):
        st["status"] = "mastered"
        st["mastered_at"] = now
        st["review_interval_index"] = 0
        st["next_review_at"] = now + SPACED_INTERVALS_DAYS[0] * 86400
        mastered_now = true

    # A mastered skill coming up for review that's answered correctly advances
    # the spaced-repetition interval; missed reviews knock it back to "active".
    elif st["status"] == "mastered":
        if correct:
            st["review_interval_index"] = min(st["review_interval_index"] + 1, SPACED_INTERVALS_DAYS.size() - 1)
            st["next_review_at"] = now + SPACED_INTERVALS_DAYS[st["review_interval_index"]] * 86400
        else:
            st["status"] = "active"
            st["review_interval_index"] = 0

    _save_state(child_id)
    AttemptLog.log_attempt(child_id, item_id, skill_id, correct, hint_count, latency_ms)

    if mastered_now:
        refresh_unlocks(child_id)

    return {
        "skill_id": skill_id,
        "mastered_now": mastered_now,
        "needs_easier_modality": st["needs_easier_modality"],
        "success_rate": st["success_rate"],
    }

func _recompute_rates(st: Dictionary) -> void:
    var n: int = st["attempts_window"].size()
    if n == 0:
        st["success_rate"] = 0.0
        st["avg_latency_ms"] = 0.0
        return
    var correct_count := 0
    for c in st["attempts_window"]:
        if c:
            correct_count += 1
    st["success_rate"] = float(correct_count) / float(n)

    var total_latency := 0
    for l in st["latency_window"]:
        total_latency += l
    st["avg_latency_ms"] = float(total_latency) / float(n)

func _meets_mastery(st: Dictionary) -> bool:
func _meets_mastery(st: Dictionary) -> bool:
    var n: int = st["attempts_window"].size()
    if n < MIN_ATTEMPTS_FOR_MASTERY:
        return false
    if st["success_rate"] < MASTERY_SUCCESS_RATE:
        return false
    # No hinted corrects in the current window — mastery must be independent.
    for h in st["hint_window"]:
        if h > 0:
            return false
    return true

## Picks the next item to serve: prioritizes active skills with lower
## success rate (needs practice), and mastered skills due for spaced review.
func select_next_item(child_id: String) -> Dictionary:
    refresh_unlocks(child_id)
    var now := Time.get_unix_time_from_system()

    # Due reviews take priority so mastery doesn't silently decay.
    for skill_id in SkillGraph.get_all_skill_ids():
        var st := get_state(child_id, skill_id)
        if st["status"] == "mastered" and st["next_review_at"] != -1 and st["next_review_at"] <= now:
            return _pick_item_for_skill(skill_id, st)

    var active_skills: Array = SkillGraph.get_all_skill_ids().filter(
        func(sid): return get_status(child_id, sid) == "active"
    )
    if active_skills.is_empty():
        return {}

    # Weight toward the skill needing the most practice.
    active_skills.sort_custom(func(a, b):
        return get_state(child_id, a)["success_rate"] < get_state(child_id, b)["success_rate"]
    )
    var chosen_skill: String = active_skills[0]
    return _pick_item_for_skill(chosen_skill, get_state(child_id, chosen_skill))

func _pick_item_for_skill(skill_id: String, st: Dictionary) -> Dictionary:
    var items := SkillGraph.get_items_for_skill(skill_id)
    if items.is_empty():
        return {}
    if st["needs_easier_modality"] or st["success_rate"] < 0.5:
        items = items.duplicate()
        items.sort_custom(func(a, b): return a["difficulty_weight"] < b["difficulty_weight"])
        return items[0]
    # Otherwise pick a random item roughly matched to recent performance.
    return items[randi() % items.size()]

# ---- Persistence (local JSON, one file per child) ----

func _save_path(child_id: String) -> String:
    return "user://mastery_%s.json" % child_id

func _save_state(child_id: String) -> void:
    var f := FileAccess.open(_save_path(child_id), FileAccess.WRITE)
    f.store_string(JSON.stringify(_state[child_id]))

func _load_state(child_id: String) -> void:
    var path := _save_path(child_id)
    if not FileAccess.file_exists(path):
        return
    var f := FileAccess.open(path, FileAccess.READ)
    var parsed = JSON.parse_string(f.get_as_text())
    if parsed != null:
        _state[child_id] = parsed
