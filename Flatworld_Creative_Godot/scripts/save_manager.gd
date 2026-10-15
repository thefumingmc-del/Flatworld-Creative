extends RefCounted
class_name SaveManager

const SAVE_PATH := "user://flatworld_creative_world.json"
const TEMP_PATH := "user://flatworld_creative_world.tmp"
const BACKUP_PATH := "user://flatworld_creative_world.bak"

static func save_world(data: Dictionary) -> bool:
    # Write a complete temporary file first. Keep the previous valid save as a
    # backup until the replacement has been renamed into place; this avoids
    # leaving an empty/corrupt world file if Android suspends during a write.
    var file := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Save failed: could not open temporary world save")
        return false
    file.store_string(JSON.stringify(data))
    file.flush()
    var write_error := file.get_error()
    file.close()
    if write_error != OK:
        push_error("Save failed while writing temporary world save")
        return false

    var save_absolute := ProjectSettings.globalize_path(SAVE_PATH)
    var temp_absolute := ProjectSettings.globalize_path(TEMP_PATH)
    var backup_absolute := ProjectSettings.globalize_path(BACKUP_PATH)

    if FileAccess.file_exists(SAVE_PATH):
        if FileAccess.file_exists(BACKUP_PATH):
            var remove_error := DirAccess.remove_absolute(backup_absolute)
            if remove_error != OK:
                push_error("Save failed: could not rotate previous backup")
                return false
        var backup_error := DirAccess.rename_absolute(save_absolute, backup_absolute)
        if backup_error != OK:
            push_error("Save failed: could not preserve previous world save")
            return false

    var replace_error := DirAccess.rename_absolute(temp_absolute, save_absolute)
    if replace_error != OK:
        # Restore the prior save if replacing the current file failed.
        if FileAccess.file_exists(BACKUP_PATH) and not FileAccess.file_exists(SAVE_PATH):
            DirAccess.rename_absolute(backup_absolute, save_absolute)
        push_error("Save failed: could not move completed temporary save into place")
        return false
    return true

static func load_world() -> Dictionary:
    # If the main file is damaged or the app was interrupted between renames,
    # load the first valid backup/temp candidate rather than discarding the world.
    for path in [SAVE_PATH, BACKUP_PATH, TEMP_PATH]:
        if not FileAccess.file_exists(path):
            continue
        var file := FileAccess.open(path, FileAccess.READ)
        if file == null:
            continue
        var text_value := file.get_as_text()
        file.close()
        var parsed: Variant = JSON.parse_string(text_value)
        if parsed is Dictionary:
            return parsed
    return {}

static func save_exists() -> bool:
    return FileAccess.file_exists(SAVE_PATH) or FileAccess.file_exists(BACKUP_PATH) or FileAccess.file_exists(TEMP_PATH)
