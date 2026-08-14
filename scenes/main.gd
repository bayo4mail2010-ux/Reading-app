extends Node

func _ready() -> void:
	print("Autoloads loaded successfully:")
	print("- SkillGraph: ", SkillGraph != null)
	print("- MasteryTracker: ", MasteryTracker != null)
	print("- AttemptLog: ", AttemptLog != null)
	print("- PlacementSession: ", PlacementSession != null)
	print("- Companion: ", Companion != null)
	print("Skill count: ", SkillGraph.get_all_skill_ids().size())
