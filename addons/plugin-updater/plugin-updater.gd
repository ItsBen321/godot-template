@tool
extends EditorScript

const PLUGINS_FILE_PATH := "res://addons/plugin-updater/PLUGINS.md"
const ADDONS_ROOT_PATH := "res://addons"
const DOWNLOADS_PATH := "user://plugin-updater-downloads"
const BACKUPS_PATH := "user://plugin-updater-backups"
const PLUGIN_CONFIG_FILE := "plugin.cfg"


func _run() -> void:
	var github_links: Array[String] = _load_github_links()
	if github_links.size() == 0:
		print("No GitHub plugin links found")
		return

	print("GitHub plugin links fetched:", github_links.size())

	var enabled_plugins: PackedStringArray = _get_enabled_plugins()
	_disable_enabled_plugins(enabled_plugins)

	var downloads_root_path: String = ProjectSettings.globalize_path(DOWNLOADS_PATH)
	var prepare_error: Error = _prepare_download_root(downloads_root_path)
	if prepare_error != OK:
		push_error("Failed to prepare plugin download folder: %s" % error_string(prepare_error))
		_restore_enabled_plugins(enabled_plugins)
		return

	var downloads_path: String = _make_download_session_path(downloads_root_path)
	var make_session_error: Error = DirAccess.make_dir_recursive_absolute(downloads_path)
	if make_session_error != OK:
		push_error("Failed to create plugin download session folder: %s" % error_string(make_session_error))
		_restore_enabled_plugins(enabled_plugins)
		return

	var installed_plugins: int = 0
	var updated_plugins: int = 0
	var failed_operations: int = 0
	var filesystem_needs_refresh := false
	var changed_gdextension_plugins := PackedStringArray()
	var link_index: int = 0
	for github_link: String in github_links:
		var clone_path: String = downloads_path.path_join("repo_%d" % link_index)
		link_index += 1

		var git_output: Array = []
		var clone_exit_code: int = OS.execute(
			"git",
			PackedStringArray(["clone", "--depth", "1", github_link, clone_path]),
			git_output,
			true,
			false
		)
		if clone_exit_code != OK:
			failed_operations += 1
			push_warning("Failed to clone %s: %s" % [github_link, str(git_output)])
			continue

		var cloned_addons_path: String = clone_path.path_join("addons")
		var cloned_addons_dir: DirAccess = DirAccess.open(cloned_addons_path)
		if cloned_addons_dir == null:
			push_warning("No addons folder found in cloned repository: %s" % github_link)

		var addon_sources: Array[Dictionary] = _get_editor_plugin_sources(cloned_addons_path)
		if addon_sources.is_empty() or _validate_plugin_sources(addon_sources) != OK:
			var release_sources: Array[Dictionary] = _download_latest_release_addon_sources(
				github_link,
				downloads_path,
				link_index
			)
			if not release_sources.is_empty() and _validate_plugin_sources(release_sources) == OK:
				addon_sources = release_sources

		if addon_sources.is_empty():
			failed_operations += 1
			push_warning("No installable editor plugin folders found for repository: %s" % github_link)
			continue

		for source_info: Dictionary in addon_sources:
			var plugin_folder: String = source_info["folder"]
			var source_path: String = source_info["source_path"]
			var validation_error: Error = _validate_plugin_source(plugin_folder, source_path)
			if validation_error != OK:
				failed_operations += 1
				push_warning("Skipping invalid plugin package %s: %s" % [plugin_folder, error_string(validation_error)])
				continue

			var target_path: String = ProjectSettings.globalize_path(ADDONS_ROOT_PATH.path_join(plugin_folder))
			var target_exists: bool = DirAccess.dir_exists_absolute(target_path)
			var source_has_gdextension := _get_gdextension_files(source_path).size() > 0
			var install_error: Error = _install_or_update_plugin(source_path, target_path, source_has_gdextension)
			if install_error == OK:
				filesystem_needs_refresh = true
				if source_has_gdextension:
					_append_unique(changed_gdextension_plugins, plugin_folder)

				if target_exists:
					updated_plugins += 1
					print("Updated plugin:", plugin_folder)
				else:
					installed_plugins += 1
					print("Installed plugin:", plugin_folder)
			else:
				failed_operations += 1
				var action := "update" if target_exists else "install"
				push_warning(
					"Failed to %s plugin %s: %s" % [action, plugin_folder, error_string(install_error)]
				)

	if filesystem_needs_refresh and changed_gdextension_plugins.is_empty():
		_refresh_editor_filesystem()
	elif filesystem_needs_refresh:
		push_warning("Skipped immediate filesystem refresh because GDExtension plugins changed. Restart the editor.")

	_restore_enabled_plugins(enabled_plugins, changed_gdextension_plugins)
	_cleanup_download_session(downloads_path)
	if not changed_gdextension_plugins.is_empty():
		push_warning(
			"GDExtension plugins updated and left disabled until restart: %s"
			% ", ".join(changed_gdextension_plugins)
		)

	print(
		"Plugin downloads complete. Installed: %d. Updated: %d. Failures: %d."
		% [installed_plugins, updated_plugins, failed_operations]
	)


func _load_github_links() -> Array[String]:
	var plugins_file := FileAccess.open(PLUGINS_FILE_PATH, FileAccess.READ)
	if plugins_file == null:
		push_error("Failed to open PLUGINS.md")
		return []

	var github_links: Array[String] = []
	while not plugins_file.eof_reached():
		var line: String = plugins_file.get_line().strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("https://github.com/") or line.begins_with("http://github.com/"):
			github_links.append(line)
		else:
			push_warning("Invalid GitHub link in PLUGINS.md: %s" % line)
	plugins_file.close()
	return github_links


func _get_enabled_plugins() -> PackedStringArray:
	var enabled_plugins_setting: Variant = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	var enabled_plugins: PackedStringArray = PackedStringArray()
	if enabled_plugins_setting is PackedStringArray:
		enabled_plugins = enabled_plugins_setting
	elif enabled_plugins_setting is Array:
		for plugin_entry in enabled_plugins_setting:
			if plugin_entry is String:
				enabled_plugins.append(plugin_entry)
			elif plugin_entry is StringName:
				enabled_plugins.append(plugin_entry as String)

	return enabled_plugins


func _disable_enabled_plugins(enabled_plugins: PackedStringArray) -> void:
	if enabled_plugins.size() > 0:
		for plugin_id: String in enabled_plugins:
			var plugin_name: String = _plugin_name_from_enabled_entry(plugin_id)
			if plugin_name.is_empty():
				continue

			print("Disabling plugin:", plugin_name)
			EditorInterface.set_plugin_enabled(plugin_name, false)
	else:
		print("No enabled editor plugins found to disable")


func _restore_enabled_plugins(
	enabled_plugins: PackedStringArray,
	defer_runtime_plugins: PackedStringArray = PackedStringArray()
) -> void:
	if enabled_plugins.size() == 0:
		return

	var enabled_plugins_to_save := PackedStringArray()
	for plugin_id: String in enabled_plugins:
		var plugin_name: String = _plugin_name_from_enabled_entry(plugin_id)
		if plugin_name.is_empty():
			continue

		if not _plugin_config_exists(plugin_name):
			push_warning("Cannot re-enable missing plugin: %s" % plugin_name)
			continue

		enabled_plugins_to_save.append(_plugin_config_path(plugin_name))
		if defer_runtime_plugins.has(plugin_name):
			print("Deferring plugin re-enable until restart:", plugin_name)
			continue

		print("Re-enabling plugin:", plugin_name)
		EditorInterface.set_plugin_enabled(plugin_name, true)

	ProjectSettings.set_setting("editor_plugins/enabled", enabled_plugins_to_save)
	var save_error: Error = ProjectSettings.save()
	if save_error != OK:
		push_warning("Failed to save restored plugin state: %s" % error_string(save_error))


func _prepare_download_root(downloads_path: String) -> Error:
	var make_downloads_error: Error = DirAccess.make_dir_recursive_absolute(downloads_path)
	if make_downloads_error != OK:
		return make_downloads_error

	return OK


func _make_download_session_path(downloads_root_path: String) -> String:
	return downloads_root_path.path_join(
		"run_%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	)


func _cleanup_download_session(downloads_path: String) -> void:
	var cleanup_error: Error = _remove_dir_recursive(downloads_path)
	if cleanup_error != OK:
		push_warning("Failed to clear plugin download session folder: %s" % error_string(cleanup_error))


func _get_editor_plugin_sources(addons_path: String) -> Array[Dictionary]:
	var addon_sources: Array[Dictionary] = []
	var addons_dir: DirAccess = DirAccess.open(addons_path)
	if addons_dir == null:
		return addon_sources

	addons_dir.list_dir_begin()
	var plugin_folder: String = addons_dir.get_next()
	while not plugin_folder.is_empty():
		if _is_directory_entry(plugin_folder, addons_dir):
			var source_path: String = addons_path.path_join(plugin_folder)
			if _is_editor_plugin_folder(source_path):
				addon_sources.append({
					"folder": plugin_folder,
					"source_path": source_path,
				})
			else:
				push_warning("Skipping addon folder without plugin.cfg: %s" % plugin_folder)

		plugin_folder = addons_dir.get_next()
	addons_dir.list_dir_end()

	return addon_sources


func _download_latest_release_addon_sources(
	github_link: String,
	downloads_path: String,
	link_index: int
) -> Array[Dictionary]:
	var release_sources: Array[Dictionary] = []
	var repo_parts: PackedStringArray = _get_github_repo_parts(github_link)
	if repo_parts.size() != 2:
		return release_sources

	var api_path: String = downloads_path.path_join("release_%d.json" % link_index)
	var api_url := "https://api.github.com/repos/%s/%s/releases/latest" % [repo_parts[0], repo_parts[1]]
	var api_error: Error = _download_file(api_url, api_path, PackedStringArray([
		"Accept: application/vnd.github+json",
		"User-Agent: plugin-updater",
	]))
	if api_error != OK:
		push_warning("Failed to fetch latest GitHub release for %s: %s" % [github_link, error_string(api_error)])
		return release_sources

	var release_zip_url: String = _get_release_zip_asset_url(api_path)
	if release_zip_url.is_empty():
		push_warning("No release zip asset found for repository: %s" % github_link)
		return release_sources

	var zip_path: String = downloads_path.path_join("release_%d.zip" % link_index)
	var zip_error: Error = _download_file(release_zip_url, zip_path)
	if zip_error != OK:
		push_warning("Failed to download release package for %s: %s" % [github_link, error_string(zip_error)])
		return release_sources

	var extract_path: String = downloads_path.path_join("release_%d" % link_index)
	var extract_error: Error = _extract_zip(zip_path, extract_path)
	if extract_error != OK:
		push_warning("Failed to extract release package for %s: %s" % [github_link, error_string(extract_error)])
		return release_sources

	_collect_editor_plugin_sources_recursive(extract_path, release_sources)
	if not release_sources.is_empty():
		print("Using latest release package for:", github_link)

	return release_sources


func _get_github_repo_parts(github_link: String) -> PackedStringArray:
	var normalized_link := github_link.replace("\\", "/").trim_suffix(".git").trim_suffix("/")
	var github_marker := "github.com/"
	var github_marker_index := normalized_link.find(github_marker)
	if github_marker_index == -1:
		return PackedStringArray()

	var repo_path := normalized_link.substr(github_marker_index + github_marker.length())
	var repo_path_parts := repo_path.split("/", false)
	if repo_path_parts.size() < 2:
		return PackedStringArray()

	return PackedStringArray([repo_path_parts[0], repo_path_parts[1]])


func _download_file(url: String, target_path: String, headers: PackedStringArray = PackedStringArray()) -> Error:
	var args := PackedStringArray(["-fL", "-sS"])
	if OS.get_name() == "Windows":
		args.append("--ssl-no-revoke")

	for header: String in headers:
		args.append_array(PackedStringArray(["-H", header]))

	args.append_array(PackedStringArray(["-o", target_path, url]))

	var curl_output: Array = []
	var curl_exit_code: int = OS.execute("curl", args, curl_output, true, false)
	if curl_exit_code == OK:
		return OK

	push_warning("curl failed for %s: %s" % [url, str(curl_output)])
	if OS.get_name() != "Windows":
		return _download_file_with_wget(url, target_path, headers)

	return FAILED


func _download_file_with_wget(url: String, target_path: String, headers: PackedStringArray) -> Error:
	var args := PackedStringArray(["-q"])
	for header: String in headers:
		args.append_array(PackedStringArray(["--header", header]))

	args.append_array(PackedStringArray(["-O", target_path, url]))

	var wget_output: Array = []
	var wget_exit_code: int = OS.execute("wget", args, wget_output, true, false)
	if wget_exit_code != OK:
		push_warning("wget failed for %s: %s" % [url, str(wget_output)])
		return FAILED

	return OK


func _get_release_zip_asset_url(api_path: String) -> String:
	var api_file := FileAccess.open(api_path, FileAccess.READ)
	if api_file == null:
		return ""

	var release_data: Variant = JSON.parse_string(api_file.get_as_text())
	if not release_data is Dictionary:
		return ""

	var assets: Variant = release_data.get("assets", [])
	if not assets is Array:
		return ""

	for asset: Variant in assets:
		if not asset is Dictionary:
			continue

		var asset_name := str(asset.get("name", ""))
		var download_url := str(asset.get("browser_download_url", ""))
		if asset_name.ends_with(".zip") and not download_url.is_empty():
			return download_url

	return ""


func _extract_zip(zip_path: String, extract_path: String) -> Error:
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(extract_path)
	if make_dir_error != OK:
		return make_dir_error

	var zip_reader := ZIPReader.new()
	var open_error: Error = zip_reader.open(zip_path)
	if open_error != OK:
		return open_error

	for zip_entry_path: String in zip_reader.get_files():
		if not _is_safe_zip_path(zip_entry_path):
			zip_reader.close()
			return ERR_INVALID_DATA

		var target_path: String = extract_path.path_join(zip_entry_path)
		if zip_entry_path.ends_with("/"):
			var make_entry_dir_error: Error = DirAccess.make_dir_recursive_absolute(target_path)
			if make_entry_dir_error != OK:
				zip_reader.close()
				return make_entry_dir_error
			continue

		var make_parent_error: Error = DirAccess.make_dir_recursive_absolute(target_path.get_base_dir())
		if make_parent_error != OK:
			zip_reader.close()
			return make_parent_error

		var output_file := FileAccess.open(target_path, FileAccess.WRITE)
		if output_file == null:
			zip_reader.close()
			return FileAccess.get_open_error()

		output_file.store_buffer(zip_reader.read_file(zip_entry_path))
		output_file = null

	zip_reader.close()
	return OK


func _is_safe_zip_path(zip_entry_path: String) -> bool:
	var normalized_path := zip_entry_path.replace("\\", "/")
	if normalized_path.is_empty() or normalized_path.begins_with("/") or normalized_path.contains(":/"):
		return false

	return not normalized_path.split("/", false).has("..")


func _collect_editor_plugin_sources_recursive(search_path: String, addon_sources: Array[Dictionary]) -> void:
	if search_path.get_file() == "addons":
		addon_sources.append_array(_get_editor_plugin_sources(search_path))

	var search_dir: DirAccess = DirAccess.open(search_path)
	if search_dir == null:
		return

	search_dir.list_dir_begin()
	var entry_name: String = search_dir.get_next()
	while not entry_name.is_empty():
		if _is_directory_entry(entry_name, search_dir):
			_collect_editor_plugin_sources_recursive(search_path.path_join(entry_name), addon_sources)

		entry_name = search_dir.get_next()
	search_dir.list_dir_end()


func _validate_plugin_sources(addon_sources: Array[Dictionary]) -> Error:
	var validation_error := OK
	for source_info: Dictionary in addon_sources:
		var plugin_folder: String = source_info["folder"]
		var source_path: String = source_info["source_path"]
		var plugin_error: Error = _validate_plugin_source(plugin_folder, source_path)
		if plugin_error != OK:
			validation_error = plugin_error

	return validation_error


func _validate_plugin_source(plugin_folder: String, source_path: String) -> Error:
	var gdextension_files: PackedStringArray = _get_gdextension_files(source_path)
	for gdextension_file: String in gdextension_files:
		var missing_libraries: PackedStringArray = _get_missing_gdextension_libraries(
			gdextension_file,
			plugin_folder,
			source_path
		)
		if missing_libraries.size() > 0:
			for missing_library: String in missing_libraries:
				push_warning(
					"Missing GDExtension library for %s: %s" % [plugin_folder, missing_library]
				)
			return ERR_FILE_NOT_FOUND

	return OK


func _get_gdextension_files(source_path: String) -> PackedStringArray:
	var gdextension_files := PackedStringArray()
	var source_dir: DirAccess = DirAccess.open(source_path)
	if source_dir == null:
		return gdextension_files

	source_dir.list_dir_begin()
	var entry_name: String = source_dir.get_next()
	while not entry_name.is_empty():
		if not source_dir.current_is_dir() and entry_name.get_extension() == "gdextension":
			gdextension_files.append(source_path.path_join(entry_name))

		entry_name = source_dir.get_next()
	source_dir.list_dir_end()

	return gdextension_files


func _get_missing_gdextension_libraries(
	gdextension_path: String,
	plugin_folder: String,
	source_path: String
) -> PackedStringArray:
	var missing_libraries := PackedStringArray()
	var gdextension_file := FileAccess.open(gdextension_path, FileAccess.READ)
	if gdextension_file == null:
		missing_libraries.append(gdextension_path)
		return missing_libraries

	var in_libraries_section := false
	while gdextension_file.get_position() < gdextension_file.get_length():
		var line := gdextension_file.get_line().strip_edges()
		if line.is_empty() or line.begins_with(";") or line.begins_with("#"):
			continue

		if line.begins_with("[") and line.ends_with("]"):
			in_libraries_section = line == "[libraries]"
			continue

		if not in_libraries_section:
			continue

		var separator_index := line.find("=")
		if separator_index == -1:
			continue

		var library_key := line.substr(0, separator_index).strip_edges()
		if not _gdextension_library_key_matches_current_platform(library_key):
			continue

		var library_path := _unquote_string(line.substr(separator_index + 1).strip_edges())
		var resolved_path := _resolve_gdextension_library_path(library_path, plugin_folder, source_path)
		if resolved_path.is_empty() or not FileAccess.file_exists(resolved_path):
			missing_libraries.append(library_path)

	return missing_libraries


func _gdextension_library_key_matches_current_platform(library_key: String) -> bool:
	var normalized_key := library_key.to_lower()
	var platform_name := _current_gdextension_platform_name()
	if platform_name.is_empty() or not normalized_key.begins_with(platform_name):
		return false

	var architecture_name := Engine.get_architecture_name().to_lower()
	if normalized_key.contains("x86_64") and architecture_name != "x86_64":
		return false
	if normalized_key.contains("arm64") and not architecture_name.contains("arm64"):
		return false

	return true


func _current_gdextension_platform_name() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"macOS":
			return "macos"
		"Linux":
			return "linux"
		_:
			return ""


func _resolve_gdextension_library_path(library_path: String, plugin_folder: String, source_path: String) -> String:
	var addon_prefix := ADDONS_ROOT_PATH.path_join(plugin_folder)
	if library_path.begins_with(addon_prefix + "/"):
		return source_path.path_join(library_path.trim_prefix(addon_prefix + "/"))

	if library_path.begins_with("res://") or library_path.begins_with("user://"):
		return ProjectSettings.globalize_path(library_path)

	if library_path.find(":/") != -1 or library_path.begins_with("/"):
		return library_path

	return source_path.path_join(library_path)


func _unquote_string(value: String) -> String:
	if value.length() >= 2:
		if value.begins_with("\"") and value.ends_with("\""):
			return value.substr(1, value.length() - 2)
		if value.begins_with("'") and value.ends_with("'"):
			return value.substr(1, value.length() - 2)

	return value


func _install_or_update_plugin(
	source_path: String,
	target_path: String,
	keep_backup_after_update: bool = false
) -> Error:
	var target_exists := DirAccess.dir_exists_absolute(target_path)
	var temp_path := "%s.plugin_updater_tmp" % target_path
	var backup_path := _make_plugin_backup_path(target_path)

	var cleanup_error: Error = _remove_dir_recursive(temp_path)
	if cleanup_error != OK:
		return cleanup_error

	cleanup_error = _remove_dir_recursive(backup_path)
	if cleanup_error != OK:
		return cleanup_error

	var copy_error: Error = _copy_dir_recursive(source_path, temp_path)
	if copy_error != OK:
		_remove_dir_recursive(temp_path)
		return copy_error

	if target_exists:
		var backup_error: Error = DirAccess.rename_absolute(target_path, backup_path)
		if backup_error != OK:
			_remove_dir_recursive(temp_path)
			return backup_error

	var replace_error: Error = DirAccess.rename_absolute(temp_path, target_path)
	if replace_error != OK:
		if target_exists:
			var restore_error: Error = DirAccess.rename_absolute(backup_path, target_path)
			if restore_error != OK:
				push_error("Failed to restore plugin backup at %s: %s" % [target_path, error_string(restore_error)])
		return replace_error

	if target_exists and not keep_backup_after_update:
		var remove_backup_error: Error = _remove_dir_recursive(backup_path)
		if remove_backup_error != OK:
			push_warning("Updated plugin but failed to remove backup folder: %s" % error_string(remove_backup_error))
	elif target_exists:
		push_warning("Kept previous GDExtension plugin backup until editor restart: %s" % backup_path)

	return OK


func _make_plugin_backup_path(target_path: String) -> String:
	var backup_root := ProjectSettings.globalize_path(BACKUPS_PATH)
	var make_backup_root_error: Error = DirAccess.make_dir_recursive_absolute(backup_root)
	if make_backup_root_error != OK:
		push_warning("Failed to create plugin backup folder: %s" % error_string(make_backup_root_error))
		return "%s.plugin_updater_backup" % target_path

	return backup_root.path_join(
		"%s_%d_%d" % [target_path.get_file(), Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	)


func _append_unique(values: PackedStringArray, value: String) -> void:
	if values.has(value):
		return

	values.append(value)


func _refresh_editor_filesystem() -> void:
	var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if editor_filesystem == null:
		push_warning("Could not refresh editor filesystem because EditorFileSystem is unavailable")
		return

	if editor_filesystem.is_scanning():
		print("Editor filesystem scan is already running")
		return

	editor_filesystem.scan()
	print("Refreshing editor filesystem")


func _is_directory_entry(entry_name: String, dir: DirAccess) -> bool:
	if entry_name == "." or entry_name == ".." or entry_name.begins_with("."):
		return false

	return dir.current_is_dir()


func _is_editor_plugin_folder(folder_path: String) -> bool:
	return FileAccess.file_exists(folder_path.path_join(PLUGIN_CONFIG_FILE))


func _plugin_config_exists(plugin_name: String) -> bool:
	return FileAccess.file_exists(_plugin_config_path(plugin_name))


func _plugin_config_path(plugin_name: String) -> String:
	return ADDONS_ROOT_PATH.path_join(plugin_name).path_join(PLUGIN_CONFIG_FILE)


func _plugin_name_from_enabled_entry(plugin_entry: String) -> String:
	var normalized_entry := plugin_entry.replace("\\", "/")
	if normalized_entry.ends_with("/%s" % PLUGIN_CONFIG_FILE):
		return normalized_entry.get_base_dir().get_file()

	return normalized_entry.get_file()


func _remove_dir_recursive(dir_path: String) -> Error:
	if not DirAccess.dir_exists_absolute(dir_path):
		return OK

	_make_path_removable(dir_path, true)
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return ERR_CANT_OPEN

	dir.list_dir_begin()
	var entry_name: String = dir.get_next()
	while not entry_name.is_empty():
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue

		var entry_path: String = dir_path.path_join(entry_name)
		var remove_error: Error = OK
		var entry_is_dir := dir.current_is_dir()
		_make_path_removable(entry_path, entry_is_dir)
		if entry_is_dir:
			remove_error = _remove_dir_recursive(entry_path)
		else:
			remove_error = DirAccess.remove_absolute(entry_path)

		if remove_error != OK:
			dir.list_dir_end()
			return remove_error

		entry_name = dir.get_next()
	dir.list_dir_end()

	_make_path_removable(dir_path, true)
	return DirAccess.remove_absolute(dir_path)


func _make_path_removable(path: String, is_directory: bool) -> void:
	if _supports_unix_permissions():
		var permissions := FileAccess.get_unix_permissions(path)
		if permissions >= 0:
			var writable_permissions: int = permissions | FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
			if is_directory:
				writable_permissions |= FileAccess.UNIX_EXECUTE_OWNER

			if writable_permissions != permissions:
				var unix_error: Error = FileAccess.set_unix_permissions(path, writable_permissions)
				if unix_error != OK:
					push_warning("Failed to update UNIX permissions on %s: %s" % [path, error_string(unix_error)])

	if not _supports_file_attributes():
		return

	if FileAccess.get_read_only_attribute(path):
		var read_only_error: Error = FileAccess.set_read_only_attribute(path, false)
		if read_only_error != OK:
			push_warning("Failed to clear read-only attribute on %s: %s" % [path, error_string(read_only_error)])

	if FileAccess.get_hidden_attribute(path):
		var hidden_error: Error = FileAccess.set_hidden_attribute(path, false)
		if hidden_error != OK:
			push_warning("Failed to clear hidden attribute on %s: %s" % [path, error_string(hidden_error)])


func _supports_file_attributes() -> bool:
	return OS.get_name() in ["Windows", "macOS", "iOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]


func _supports_unix_permissions() -> bool:
	return OS.get_name() in ["Linux", "macOS", "iOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]


func _copy_dir_recursive(source_path: String, target_path: String) -> Error:
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(target_path)
	if make_dir_error != OK:
		return make_dir_error

	var source_dir: DirAccess = DirAccess.open(source_path)
	if source_dir == null:
		return ERR_CANT_OPEN

	source_dir.list_dir_begin()
	var entry_name: String = source_dir.get_next()
	while not entry_name.is_empty():
		if entry_name == "." or entry_name == "..":
			entry_name = source_dir.get_next()
			continue

		var source_entry_path: String = source_path.path_join(entry_name)
		var target_entry_path: String = target_path.path_join(entry_name)
		var copy_error: Error = OK
		if source_dir.current_is_dir():
			copy_error = _copy_dir_recursive(source_entry_path, target_entry_path)
		else:
			copy_error = DirAccess.copy_absolute(source_entry_path, target_entry_path)

		if copy_error != OK:
			source_dir.list_dir_end()
			return copy_error

		entry_name = source_dir.get_next()
	source_dir.list_dir_end()

	return OK
