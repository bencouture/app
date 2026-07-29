# Calendar sync — implementation plan

One-way sync: Vikunja tasks (with due dates) → a device calendar, so they show
up in Google Calendar / any calendar app reading the device's calendar
provider. No two-way sync (editing an event does not change the task) —
that needs polling/webhooks + conflict resolution and isn't worth it for a
"see my tasks in my calendar" feature.

## Why this is small

The app already has this exact shape of feature, twice:

- `lib/presentation/manager/notifications.dart` (`scheduleDueNotifications`) —
  fetches tasks by filter string, wipes old state, loops, creates one
  local-notification per task.
- `lib/presentation/manager/widget_controller.dart` (`updateWidget`) —
  fetches tasks, pushes them to native (home-screen widget) storage.
- `lib/core/background_work.dart` (`updateTasks`) — the Workmanager periodic
  job that already calls both of the above, on the user's existing
  `refreshInterval` setting.

Calendar sync is a third thing that looks exactly like the first two, called
from the same place. No new background scheduling infra needed.

Settings toggles also already have a fixed 4-layer pattern (see
`getDynamicColors`/`setDynamicColors` across `settings_data_source.dart` →
`settings_repository.dart` → `settings_repository_impl.dart` →
`settings_controller.dart` → `settings_page.dart`). Reuse it as-is.

## Dependency

Add `device_calendar_plus` to `pubspec.yaml` (not the original
`device_calendar` — that one has fewer recent updates and doesn't cleanly
support iOS 17's split full/write-only calendar access; `device_calendar_plus`
does, via `requestPermissions(level: CalendarAccessLevel...)`). Covers
Android (`CalendarContract`) and iOS (`EventKit`) with one API:
`retrieveCalendars()`, `createCalendar()`, `createOrUpdateEvent()`,
`deleteEvent()`.

Skipped: writing raw `CalendarContract`/`EventKit` platform channels by hand
— this is rung 5 on the ladder (already-installed-tier effort, just not
installed yet). Verify current pub.dev maintenance status for both packages
at implementation time, this space shifts.

## Permissions

- Android manifest (`android/app/src/main/AndroidManifest.xml`): add
  `READ_CALENDAR` / `WRITE_CALENDAR`.
- iOS (`ios/Runner/Info.plist`): add `NSCalendarsUsageDescription` (and
  `NSCalendarsFullAccessUsageDescription` on iOS 17+).
- Request at runtime via the plugin's own
  `requestPermissions()` — don't reuse `permission_handler` for this, the
  plugin owns its own permission call, same as how
  `flutter_local_notifications` owns its exact-alarm permission request in
  `notifications.dart:_requestAndroidExactAlarmPermission`.
- **Timing: only call `requestPermissions()` from the "Sync tasks to
  calendar" `SwitchListTile`'s `onChanged`, when the user flips it on** —
  never at app startup, never unconditionally in `initNotifications()` or
  `main.dart`. Manifest entries alone don't trigger a system prompt; the
  prompt only fires on the first actual calendar-plugin call, so as long
  as nothing calls `retrieveCalendars()`/`requestPermissions()` before the
  toggle is on, the user never sees the calendar permission dialog until
  they've asked for the feature. If the user denies, flip the switch back
  off and don't retry silently in the background job.
- `syncCalendar()` itself (called every background run) must bail out via
  the `getCalendarSyncEnabled()` check *before* touching
  the calendar plugin at all — that check already exists in the sync
  manager sketch below, it's what keeps a disabled feature from ever
  reaching the permission-gated API.

## Settings

New file-by-file additions, copying the `dynamicColors` pattern exactly:

1. `settings_data_source.dart` — `getCalendarSyncEnabled`/
   `setCalendarSyncEnabled` (bool, secure storage `"calendar_sync_enabled"`),
   `getSyncCalendarId`/`setSyncCalendarId` (String?, storage
   `"sync_calendar_id"`).
2. `settings_repository.dart` (abstract) + `settings_repository_impl.dart` —
   pass-through, same shape as every other pair in the file.
3. `settings_controller.dart` — add both to `getAll()` and
   `SettingsPageState`, add setter methods mirroring `setDynamicColors`.
4. `settings_page.dart` — one `SwitchListTile` ("Sync tasks to calendar").
   `onChanged`: if turning on, call `requestPermissions()` first — this is
   the first-ever calendar-plugin call, so it's also the first moment the
   OS permission dialog can appear. If denied, leave the switch off and
   stop (no dropdown, no `retrieveCalendars()` call — that also needs the
   permission). If granted, show a `DropdownButton` populated from
   `retrieveCalendars()` (writable calendars only) — same dropdown pattern
   already used for `themeMode`/`localeOverride`. Include a "Vikunja (new
   calendar)" option that calls `createCalendar()` once and stores the
   returned id — so a Google Workspace/CalDAV account isn't required, and
   existing DAVx5-synced calendars are also selectable if the user has one.

Skipped: a separate "which task filters sync" setting — just sync the same
`done=false && due_date != null` set the widget/notifications already use.
Add a filter picker only if someone actually asks for it.

## Sync manager

New file: `lib/presentation/manager/calendar_sync.dart`, structured exactly
like `scheduleDueNotifications`:

```
Future<void> syncCalendar(TaskRepository taskService) async {
  if (!await settings.getCalendarSyncEnabled()) return;
  final calendarId = await settings.getSyncCalendarId();
  if (calendarId == null) return;

  final tasks = await taskService.getByFilterString(
    "done = false && due_date != null",
  );
  final mapping = await loadEventMap(); // task id -> calendar event id, secure storage JSON blob
  final stillPresent = <int>{};

  for (final task in tasks.toSuccess().body) {
    final eventId = await DeviceCalendarPlugin().createOrUpdateEvent(Event(
      calendarId,
      eventId: mapping[task.id],
      title: task.title,
      start: tz.TZDateTime.from(task.dueDate!, local),
      end: tz.TZDateTime.from(task.dueDate!.add(Duration(hours: 1)), local),
    ));
    mapping[task.id] = eventId;
    stillPresent.add(task.id);
  }

  // drop events for tasks that are done/deleted/no longer due
  for (final id in mapping.keys.toList()) {
    if (!stillPresent.contains(id)) {
      await DeviceCalendarPlugin().deleteEvent(calendarId, mapping[id]);
      mapping.remove(id);
    }
  }
  await saveEventMap(mapping);
}
```

Event-id mapping storage: reuse the same trick `widget_controller.dart`
uses for `WidgetTasks` — one JSON blob in secure storage (`Map<int, String>`
task id → calendar event id). No new local DB. Skipped: sqlite/hive — the
task count is small (one user's due tasks), a blob is fine.

## Wiring

`lib/core/background_work.dart:updateTasks()` — add one line after the
existing `updateWidget()` / `scheduleDueNotifications()` calls:

```dart
await syncCalendar(taskService);
```

That's the entire integration point. It now runs on the same cadence as the
widget and notifications, with no new trigger.

## Also call it from foreground task mutations

Wherever the app already calls `updateWidget()` after a task edit/complete
(e.g. `notifications.dart:markAsDone`, `widget_controller.dart:completeTask`),
add `syncCalendar(taskService)` alongside it, so the calendar doesn't lag
behind the background refresh interval when the user edits from inside the
app.

## Test

One `test/presentation/calendar_sync_test.dart` (project already has a
`test/presentation` dir, matches existing structure): fake `TaskRepository`
returning 2 tasks with due dates + 1 done task, fake event-id map with a
stale entry, assert `syncCalendar` creates 2 events, deletes the stale one,
and skips entirely when `getCalendarSyncEnabled()` is false. No plugin
mocking beyond that — `DeviceCalendarPlugin` calls can be behind a thin
interface only if it turns out untestable directly; don't add the interface
speculatively.

## Explicitly out of scope

- Two-way sync (calendar edit → task update).
- Syncing anything other than due date (no start/end range events, no
  recurring-task expansion into recurring calendar events — `repeatAfter`
  stays a Vikunja-only concept for now).
- Per-project calendar mapping (one calendar for all synced tasks, not one
  calendar per Vikunja project). Add if asked.

## Estimate

- Dependency + permissions: ~1 hr.
- Settings (4-layer toggle + calendar picker): ~2-3 hrs, mechanical.
- `calendar_sync.dart` + wiring + event-id mapping: ~3-4 hrs.
- Test: ~1 hr.
- Manual Android + iOS verification: ~2 hrs.

Total: roughly one weekend, most of it copying patterns already in the repo.
