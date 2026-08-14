extends Node
## Autoload: SkillGraph
## Loads static curriculum content (skills, prerequisites, items) and
## exposes read-only queries over it. This data never changes at runtime;
## per-child progress lives in MasteryTracker, not here.

var skills: Dictionary = {}                # skill_id -> skill dict
var items_by_skill: Dictionary = {}         # skill_id -> Array[item dict]
var items_by_id: Dictionary = {}            # item_id -> item dict
var prereqs_by_skill: Dictionary = {}       # skill_id -> Array[{prerequisite_skill_id, strength}]

func _ready() -> void:
    load_data()

func load_data() -> void:
    skills = _load_json_as_dict("res://data/skills.json", "skill_id")
    var items_list: Array = _load_json_array("res://data/items.json")
    for item in items_list:
        items_by_id[item["item_id"]] = item
        if not items_by_skill.has(item["skill_id"]):
            items_by_skill[item["skill_id"]] = []
        items_by_skill[item["skill_id"]].append(item)

    var prereq_list: Array = _load_json_array("res://data/skill_prerequisites.json")
    for edge in prereq_list:
        var sid = edge["skill_id"]
        if not prereqs_by_skill.has(sid):
            prereqs_by_skill[sid] = []
        prereqs_by_skill[sid].append(edge)

func _load_json_array(path: String) -> Array:
    if not FileAccess.file_exists(path):
        push_error("SkillGraph: missing data file %s" % path)
        return []
    var f := FileAccess.open(path, FileAccess.READ)
    var text := f.get_as_text()
    var parsed = JSON.parse_string(text)
    if parsed == null:
        push_error("SkillGraph: failed to parse %s" % path)
        return []
    return parsed

func _load_json_as_dict(path: String, key_field: String) -> Dictionary:
    var arr := _load_json_array(path)
    var out := {}
    for entry in arr:
        out[entry[key_field]] = entry
    return out

func get_skill(skill_id: String) -> Dictionary:
    return skills.get(skill_id, {})

func get_all_skill_ids() -> Array:
    return skills.keys()

func get_items_for_skill(skill_id: String) -> Array:
    return items_by_skill.get(skill_id, [])

func get_item(item_id: String) -> Dictionary:
    return items_by_id.get(item_id, {})

func get_prerequisites(skill_id: String) -> Array:
    return prereqs_by_skill.get(skill_id, [])

func get_hard_prerequisites(skill_id: String) -> Array:
    return get_prerequisites(skill_id).filter(func(e): return e["strength"] == "hard")

func get_soft_prerequisites(skill_id: String) -> Array:
    return get_prerequisites(skill_id).filter(func(e): return e["strength"] == "soft")

## Given a dict of skill_id -> status ("mastered"/"active"/"not_started"/"decayed"),
## returns true if all HARD prerequisites for skill_id are mastered.
func hard_prereqs_satisfied(skill_id: String, status_by_skill: Dictionary) -> bool:
    for edge in get_hard_prerequisites(skill_id):
        var pid = edge["prerequisite_skill_id"]
        if status_by_skill.get(pid, "not_started") != "mastered":
            return false
    return true

## Soft prereqs just need to be mastered OR already active (kid can dabble ahead).
func soft_prereqs_satisfied(skill_id: String, status_by_skill: Dictionary) -> bool:
    for edge in get_soft_prerequisites(skill_id):
        var pid = edge["prerequisite_skill_id"]
        var s = status_by_skill.get(pid, "not_started")
        if s != "mastered" and s != "active":
            return false
    return true

func skills_in_tier(tier: int) -> Array:
    return skills.values().filter(func(s): return s["tier"] == tier)
