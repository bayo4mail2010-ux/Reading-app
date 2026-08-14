extends Node
## Autoload: Companion
## Per-child companion state (stars, wardrobe, reward queue, growth stage,
## monster name) and the logic around it — ported from the HTML
## prototype's `companion` object, `newCompanionState()`, `applyGrowthStage()`,
## `unlockAccessory()`, and the reward-queue functions.
##
## Scope note: this ports the STATE MODEL and LOGIC only, not the visual
## rendering (monster sprite, accessory positioning, reward-certificate
## UI, wardrobe grid). Building that out means real scene work in the
## Godot editor, not just file authoring — a future scene can read this
## autoload's state and render accordingly, the same way SkillGraph and
## MasteryTracker are UI-agnostic and get consumed by whatever scene
## calls them.
##
## Like MasteryTracker, everything here is keyed by child_id, so multiple
## profiles sharing a device work the same way they do in the HTML build.

const ACCESSORIES := {
    "partyhat": {"name": "Party Hat", "icon": "🎉"},
    "bowtie": {"name": "Bow Tie", "icon": "🎀"},
    "sunglasses": {"name": "Sunglasses", "icon": "🕶️"},
    "balloon": {"name": "Balloon", "icon": "🎈"},
    "scarf": {"name": "Scarf", "icon": "🧣"},
    "cape": {"name": "Cape", "icon": "🦸"},
    "backpack": {"name": "Backpack", "icon": "🎒"},
    "book": {"name": "Book", "icon": "📖"},
    "gradcap": {"name": "Graduation Cap", "icon": "🎓"},
    "trophy": {"name": "Trophy", "icon": "🏆"},
    "magnifyglass": {"name": "Magnifying Glass", "icon": "🔍"},
    "pawprint": {"name": "Paw Print Badge", "icon": "🐾"},
    "sparkleboots": {"name": "Sparkle Boots", "icon": "👟"},
    "pencil": {"name": "Pencil", "icon": "📝"},
    "bookmark": {"name": "Bookmark", "icon": "🔖"},
    "compass": {"name": "Compass", "icon": "🧭"},
    "crown": {"name": "Crown", "icon": "👑"},
}

const SKILL_ACCESSORY := {
    "vocabulary_objects": "magnifyglass",
    "vocabulary_animals": "pawprint",
    "letter_sounds_mn": "bowtie",
    "letter_sounds_apr": "sunglasses",
    "cvc_short_a": "balloon",
    "blend_st": "scarf",
    "blend_bl": "cape",
    "sight_words_2letter": "backpack",
    "sight_words_3letter": "bookmark",
    "sight_words_4letter": "book",
    "word_families_multisyllabic": "gradcap",
    "reading_comprehension_short": "trophy",
    "sentence_building": "pencil",
    "choose_your_adventure": "compass",
}

# Growth stage thresholds (lifetime stars) — matches applyGrowthStage() in HTML.
const GROWTH_THRESHOLDS := [0, 5, 15, 30, 50]  # index+1 = stage number

# child_id -> companion state dict
var _state: Dictionary = {}

func _default_state() -> Dictionary:
    return {
        "total_stars": 0,
        "unlocked": [],           # Array[String] accessory ids"equipped": null,          # String accessory id, or null
        "hit_streak3": false,
        "hit_20_stars": false,
        "reward_text": "a special treat!",
        "reward_queue": [],        # Array[Dictionary] {type, detail}
        "correct_streak": 0,
        "session_rounds_completed": 0,
        "next_focus_milestone_index": 0,
        "last_break_prompt_at": 0,
        "large_text": false,
        "reduce_motion": false,
        "monster_name": null,
    }

func get_state(child_id: String) -> Dictionary:
    if not _state.has(child_id):
        _state[child_id] = _default_state()
    return _state[child_id]

## Wipes a profile's companion state entirely — mirrors resetProfileProgress()
## in the HTML build. Caller is responsible for also calling
## MasteryTracker's equivalent reset for skill/item progress; Companion
## only owns the companion-side state.
func reset_child(child_id: String) -> void:
    _state[child_id] = _default_state()

## Growth stage 1-5 based on lifetime stars. Matches the HTML version's
## thresholds: 0-4 -> 1, 5-14 -> 2, 15-29 -> 3, 30-49 -> 4, 50+ -> 5.
func growth_stage(child_id: String) -> int:
    var stars: int = get_state(child_id)["total_stars"]
    var stage := 1
    for i in range(GROWTH_THRESHOLDS.size()):
        if stars >= GROWTH_THRESHOLDS[i]:
            stage = i + 1
    return stage

func unlock_accessory(child_id: String, accessory_id: String) -> bool:
    var st := get_state(child_id)
    if st["unlocked"].has(accessory_id):
        return false  # already unlocked — nothing to do, matches HTML's early-return guard
    st["unlocked"].append(accessory_id)
    if st["equipped"] == null:
        st["equipped"] = accessory_id  # auto-wear the first thing they get
    return true

func equip(child_id: String, accessory_id: String) -> void:
    var st := get_state(child_id)
    if not st["unlocked"].has(accessory_id):
        return
    # Tapping the currently-equipped item again un-equips it, same toggle
    # behavior as the HTML wardrobe.
    st["equipped"] = null if st["equipped"] == accessory_id else accessory_id

## Called on every star gained (i.e. every first-try correct round) —
## mirrors the star-increment + milestone-unlock block inside
## finishCorrectRound() in the HTML build.
func add_star(child_id: String) -> void:
    var st := get_state(child_id)
    st["total_stars"] += 1
    if st["total_stars"] >= 20 and not st["hit_20_stars"]:st["hit_20_stars"] = true
        unlock_accessory(child_id, "sparkleboots")

## Streak tracking — call on a first-try correct round (increments,
## capped at 5 to match the HTML star display) or a miss (resets to 0).
func record_correct_streak(child_id: String) -> void:
    var st := get_state(child_id)
    st["correct_streak"] = min(st["correct_streak"] + 1, 5)
    if st["correct_streak"] >= 3 and not st["hit_streak3"]:
        st["hit_streak3"] = true
        unlock_accessory(child_id, "partyhat")

func reset_correct_streak(child_id: String) -> void:
    get_state(child_id)["correct_streak"] = 0

## Reward queue — a list rather than a single slot, so a mastery reward
## and a focus-milestone reward landing on the same round don't silently
## overwrite each other (a real bug this fixed in the HTML version).
func queue_reward(child_id: String, type: String, detail) -> void:
    get_state(child_id)["reward_queue"].append({"type": type, "detail": detail})

func claim_next_reward(child_id: String) -> Dictionary:
    var st := get_state(child_id)
    if st["reward_queue"].is_empty():
        return {}
    return st["reward_queue"].pop_front()

func has_pending_reward(child_id: String) -> bool:
    return not get_state(child_id)["reward_queue"].is_empty()

## Focus milestones — every 10/25/50 completed rounds in one sitting
## queues a reward. Deliberately tied to completed rounds, not elapsed
## time, so it rewards sustained engagement rather than just having the
## app open — see the HTML build's comment on checkFocusMilestone() for
## the full reasoning.
const FOCUS_MILESTONES := [10, 25, 50]

func record_round_completed(child_id: String) -> void:
    var st := get_state(child_id)
    st["session_rounds_completed"] += 1
    var idx: int = st["next_focus_milestone_index"]
    if idx < FOCUS_MILESTONES.size() and st["session_rounds_completed"] >= FOCUS_MILESTONES[idx]:
        queue_reward(child_id, "focus", FOCUS_MILESTONES[idx])
        st["next_focus_milestone_index"] += 1

## Gentle wind-down check — every 20 completed rounds, suggest (never
## force) a break. Matches shouldPromptBreak()/showBreakPrompt() in HTML.
const BREAK_INTERVAL := 20

func should_prompt_break(child_id: String) -> bool:
    var st := get_state(child_id)
    return st["session_rounds_completed"] - st["last_break_prompt_at"] >= BREAK_INTERVAL

func mark_break_prompted(child_id: String) -> void:
    var st := get_state(child_id)
    st["last_break_prompt_at"] = st["session_rounds_completed"]
