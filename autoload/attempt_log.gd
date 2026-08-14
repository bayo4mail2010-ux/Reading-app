extends Node
## Autoload: AttemptLog
## Append-only log of every attempt, persisted locally. This is the source
## of truth for analytics and the parent dashboard; MasteryTracker's state
## is a derived/cached rollup, this log is never overwritten.

# child_id -> Array[attempt dict]
var _log: Dictionary = {}
var _loaded_children: Dictionary = {}  # child_id -> bool, lazy load guard

func _ensure_loaded(child_id: String) -> void:
    if _loaded_children.has(child_id):
        return
    _loaded_children[child_id] = true
    _log[child_id] = []
    var path := _log_path(child_id)
    if not FileAccess.file_exists(path):
        return
    var f := FileAccess.open(path, FileAccess.READ)
    while not f.eof_reached():
        var line := f.get_line()
        if line.is_empty():
            continue
        var parsed = JSON.parse_string(line)
        if parsed != null:
            _log[child_id].append(parsed)

func log_attempt(child_id: String, item_id: String, skill_id: String, correct: bool, hint_count: int, latency_ms: int) -> void:
    _ensure_loaded(child_id)
    var entry := {
        "attempt_id": _log[child_id].size(),
        "child_id": child_id,
        "item_id": item_id,
        "skill_id": skill_id,
        "correct": correct,
        "hint_count": hint_count,
        "latency_ms": latency_ms,
        "timestamp": Time.get_unix_time_from_system(),
    }
    _log[child_id].append(entry)
    _append_to_disk(child_id, entry)

func get_attempts(child_id: String, since_unix: int = -1) -> Array:
    _ensure_loaded(child_id)
    if since_unix == -1:
        return _log[child_id]
    return _log[child_id].filter(func(a): return a["timestamp"] >= since_unix)

# ---- Dashboard query helpers (mirror the SQL views from the design doc) ----

## View 1: mastered skills, most recent first.
func mastered_skills(child_id: String) -> Array:
    var out := []
    for skill_id in SkillGraph.get_all_skill_ids():
        var st := MasteryTracker.get_state(child_id, skill_id)
        if st["status"] == "mastered":
            out.append({
                "skill_id": skill_id,
                "display_name": SkillGraph.get_skill(skill_id).get("display_name", skill_id),
                "mastered_at": st["mastered_at"],
            })
    out.sort_custom(func(a, b): return a["mastered_at"] > b["mastered_at"])
    return out

## View 2: per-day attempt counts and active minutes, last N days.
func daily_stats(child_id: String, days: int = 30) -> Dictionary:
    var since := Time.get_unix_time_from_system() - days * 86400
    var attempts := get_attempts(child_id, since)
    var by_day := {}  # "YYYY-MM-DD" -> {attempts, active_ms}
    for a in attempts:
        var day := Time.get_date_string_from_unix_time(a["timestamp"])
        if not by_day.has(day):
            by_day[day] = {"attempts": 0, "active_ms": 0}
        by_day[day]["attempts"] += 1
        by_day[day]["active_ms"] += a["latency_ms"]
    return by_day

## View 3: skills below 50% recent success rate, framed for parents as
## "practice together" — sorted worst-first, capped to `limit`.
func skills_needing_practice(child_id: String, limit: int = 5) -> Array:
    var out := []
    for skill_id in SkillGraph.get_all_skill_ids():
        var st := MasteryTracker.get_state(child_id, skill_id)
        if st["status"] == "active" and st["success_rate"] < 0.5 and st["attempts_window"].size() > 0:
            out.append({
                "skill_id": skill_id,
                "display_name": SkillGraph.get_skill(skill_id).get("display_name", skill_id),
                "success_rate": st["success_rate"],
            })
    out.sort_custom(func(a, b): return a["success_rate"] < b["success_rate"])
    return out.slice(0, limit)

## View 4: tier completion — mastered / total skills per tier.
func tier_progress(child_id: String) -> Dictionary:
    var out := {}  # tier -> {mastered: int, total: int}
    for skill_id in SkillGraph.get_all_skill_ids():
        var skill := SkillGraph.get_skill(skill_id)
        var tier: int = skill["tier"]
        if not out.has(tier):
            out[tier] = {"mastered": 0, "total": 0}
        out[tier]["total"] += 1
        if MasteryTracker.get_status(child_id, skill_id) == "mastered":
            out[tier]["mastered"] += 1
    return out

## View 5: specific items (not just skill categories) a child is
## struggling with — the concrete "practice this exact word/letter"
## detail one level more specific than skills_needing_practice above.
## Excludes story/sentence/adventure skills since those aren't single
## atomic words/letters; their skill-level struggle already shows in
## View 3. Requires at least 2 attempts so one unlucky miss doesn't
## get flagged, and only surfaces items below 60% accuracy.
func struggling_items(child_id: String, limit: int = 6) -> Array:
    var per_item := {}  # item_id -> {correct: int, total: int}
    for a in get_attempts(child_id):
        var iid: String = a["item_id"]
        if not per_item.has(iid):
            per_item[iid] = {"correct": 0, "total": 0}
        per_item[iid]["total"] += 1
        if a["correct"]:
            per_item[iid]["correct"] += 1

    var out := []
    for item_id in per_item:
        var rec = per_item[item_id]
        if rec["total"] < 2:
            continue
        var accuracy: float = float(rec["correct"]) / float(rec["total"])
        if accuracy >= 0.6:
            continue
        var item := SkillGraph.get_item(item_id)
        if item.is_empty():
            continue
        var skill := SkillGraph.get_skill(item["skill_id"])
        var mode: String = skill.get("mode", "recognize")
        if mode == "story" or mode == "sentence" or mode == "adventure":
            continue
        var label = item["word"] if item.get("isPicture", false) else item.get("content", item_id)
        out.append({
            "item_id": item_id,
            "label": label,
            "accuracy": accuracy,
            "attempts": rec["total"],
            "skill_name": skill.get("display_name", item["skill_id"]),
        })

    out.sort_custom(func(a, b): return a["accuracy"] < b["accuracy"])
    return out.slice(0, limit)

## Nightly-rollup-style summary; call once per day (e.g. on first app open
## of the day) rather than recomputing from the raw log on every dashboard view.
func compute_daily_rollup(child_id: String, date_unix: int) -> Dictionary:
    var day_start := date_unix - (date_unix % 86400)
    var day_end := day_start + 86400
    var attempts := get_attempts(child_id, day_start).filter(func(a): return a["timestamp"] < day_end)
    var active_ms := 0
    for a in attempts:
        active_ms += a["latency_ms"]
    var mastered_today := mastered_skills(child_id).filter(
        func(s): return s["mastered_at"] >= day_start and s["mastered_at"] < day_end
    )
    return {
        "child_id": child_id,
        "date": Time.get_date_string_from_unix_time(day_start),
        "active_minutes": active_ms / 60000.0,
        "attempts_count": attempts.size(),
        "skills_mastered_count": mastered_today.size(),
    }

# ---- Persistence: append-only JSON-lines file per child ----

func _log_path(child_id: String) -> String:
    return "user://attempts_%s.jsonl" % child_id

func _append_to_disk(child_id: String, entry: Dictionary) -> void:
    var f := FileAccess.open(_log_path(child_id), FileAccess.READ_WRITE if FileAccess.file_exists(_log_path(child_id)) else FileAccess.WRITE)
    f.seek_end()
    f.store_line(JSON.stringify(entry))
