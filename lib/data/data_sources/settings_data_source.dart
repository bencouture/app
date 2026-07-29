import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vikunja_app/core/theming/theme_mode.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';

class SettingsDatasource {
  final FlutterSecureStorage _storage;

  SettingsDatasource(this._storage);

  Future<bool> getIgnoreCertificates() {
    return _storage
        .read(key: "ignore-certificates")
        .then((value) => value == "1");
  }

  Future<void> setIgnoreCertificates(bool value) {
    return _storage.write(key: "ignore-certificates", value: value ? "1" : "0");
  }

  Future<bool> getSentryEnabled() {
    return _storage.read(key: "sentry-enabled").then((value) => value == "1");
  }

  Future<void> setSentryEnabled(bool value) {
    return _storage.write(key: "sentry-enabled", value: value ? "1" : "0");
  }

  Future<bool> getVersionNotifications() {
    return _storage
        .read(key: "get-version-notifications")
        .then((value) => value == "1");
  }

  Future<void> setVersionNotifications(bool value) {
    return _storage.write(
      key: "get-version-notifications",
      value: value ? "1" : "0",
    );
  }

  Future<int> getRefreshInterval() {
    return _storage
        .read(key: "workmanager-duration")
        .then((value) => int.tryParse(value ?? "0") ?? 0);
  }

  Future<void> setRefreshInterval(int minutes) {
    return _storage.write(
      key: "workmanager-duration",
      value: minutes.toString(),
    );
  }

  Future<FlutterThemeMode> getThemeMode() async {
    String? themeMode = await _storage.read(key: "theme_mode");
    if (themeMode == null) setThemeMode(FlutterThemeMode.system);
    switch (themeMode) {
      case "system":
        return FlutterThemeMode.system;
      case "light":
        return FlutterThemeMode.light;
      case "dark":
        return FlutterThemeMode.dark;
      default:
        return FlutterThemeMode.system;
    }
  }

  Future<void> setThemeMode(FlutterThemeMode newMode) async {
    await _storage.write(
      key: "theme_mode",
      value: newMode.toString().split('.').last,
    );
  }

  Future<void> setDynamicColors(bool dynamicColors) async {
    await _storage.write(
      key: "dynamic_colors",
      value: dynamicColors.toString(),
    );
  }

  Future<bool> getDynamicColors() async {
    String? dynamicColors = await _storage.read(key: "dynamic_colors");
    return dynamicColors == "true";
  }

  Future<bool> getLandingPageOnlyDueDateTasks() {
    return _storage
        .read(key: "landing-page-due-date-tasks")
        .then((value) => value == "1");
  }

  Future<void> setLandingPageOnlyDueDateTasks(bool value) {
    return _storage.write(
      key: "landing-page-due-date-tasks",
      value: value ? "1" : "0",
    );
  }

  Future<bool> getDisplayDoneTasks(int projectId) async {
    var value = await _storage.read(key: "display_done_tasks_list_$projectId");

    return value == "1";
  }

  Future<void> setDisplayDoneTasks(int projectId, bool value) {
    return _storage.write(
      key: "display_done_tasks_list_$projectId",
      value: value ? "1" : "0",
    );
  }

  Future<List<String>> getPastServers() async {
    String jsonString = await _storage.read(key: "recent-servers") ?? "[]";
    List<dynamic> server = jsonDecode(jsonString);
    return server.map((e) => e as String).toList();
  }

  Future<void> setPastServers(List<String> server) {
    return _storage.write(key: "recent-servers", value: jsonEncode(server));
  }

  Future<bool> getSentryDialogShown() {
    return _storage
        .read(key: "sentry-modal-shown")
        .then((value) => value == "1");
  }

  Future<void> setSentryDialogShown(bool value) {
    return _storage.write(key: "sentry-modal-shown", value: value ? "1" : "0");
  }

  Future<String?> getServer() {
    return _storage.read(key: "server-address");
  }

  Future<String?> getUserToken() {
    return _storage.read(key: "user-token");
  }

  Future<void> saveServer(String? server) {
    return _storage.write(key: "server-address", value: server);
  }

  Future<void> saveUserToken(String? token) {
    return _storage.write(key: "user-token", value: token);
  }

  Future<String?> getRefreshToken() {
    return _storage.read(key: "refresh-token");
  }

  Future<void> saveRefreshToken(String? token) {
    return _storage.write(key: "refresh-token", value: token);
  }

  Future<void> clearAuthData() async {
    await saveUserToken(null);
    await saveRefreshToken(null);
    await saveServer(null);
  }

  Future<String?> getLocaleOverride() async {
    return _storage.read(key: "locale_override");
  }

  Future<void> setLocaleOverride(String? localeCode) async {
    await _storage.write(key: "locale_override", value: localeCode);
  }

  Future<void> setCalendarSyncEnabled(bool calendarSyncEnabled) async {
    await _storage.write(
      key: "calendar_sync_enabled",
      value: calendarSyncEnabled.toString(),
    );
  }

  Future<bool> getCalendarSyncEnabled() async {
    String? calendarSyncEnabled = await _storage.read(
      key: "calendar_sync_enabled",
    );
    return calendarSyncEnabled == "true";
  }

  Future<String?> getSyncCalendarId() {
    return _storage.read(key: "sync_calendar_id");
  }

  Future<void> setSyncCalendarId(String? calendarId) {
    return _storage.write(key: "sync_calendar_id", value: calendarId);
  }

  Future<bool> getSyncAllDayTasks() async {
    return (await _storage.read(key: "calendar_sync_all_day_tasks")) == "1";
  }

  Future<void> setSyncAllDayTasks(bool value) {
    return _storage.write(
      key: "calendar_sync_all_day_tasks",
      value: value ? "1" : "0",
    );
  }

  Future<AllDayEventDisplay> getAllDayEventDisplay() async {
    switch (await _storage.read(key: "calendar_all_day_display")) {
      case "end_of_day":
        return AllDayEventDisplay.endOfDay;
      case "all_day_event":
        return AllDayEventDisplay.allDayEvent;
      default:
        return AllDayEventDisplay.midnight;
    }
  }

  Future<void> setAllDayEventDisplay(AllDayEventDisplay value) {
    final stored = switch (value) {
      AllDayEventDisplay.midnight => "midnight",
      AllDayEventDisplay.endOfDay => "end_of_day",
      AllDayEventDisplay.allDayEvent => "all_day_event",
    };
    return _storage.write(key: "calendar_all_day_display", value: stored);
  }

  // null means "use the calendar's default color".
  Future<int?> getEventColor() async {
    final stored = await _storage.read(key: "calendar_event_color");
    return stored == null ? null : int.tryParse(stored);
  }

  Future<void> setEventColor(int? color) {
    return _storage.write(
      key: "calendar_event_color",
      value: color?.toString(),
    );
  }

  // task id -> device calendar event id, for syncCalendar to know which
  // events to update vs. create, and which to delete once a task is no
  // longer open/due.
  Future<Map<int, String>> getCalendarEventMap() async {
    String jsonString = await _storage.read(key: "calendar_event_map") ?? "{}";
    Map<String, dynamic> decoded = jsonDecode(jsonString);
    return decoded.map((key, value) => MapEntry(int.parse(key), value as String));
  }

  Future<void> setCalendarEventMap(Map<int, String> eventMap) {
    final encoded = eventMap.map((key, value) => MapEntry(key.toString(), value));
    return _storage.write(key: "calendar_event_map", value: jsonEncode(encoded));
  }
}
