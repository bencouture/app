import 'package:device_calendar_plus_platform_interface/device_calendar_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikunja_app/core/network/response.dart';
import 'package:vikunja_app/data/data_sources/settings_data_source.dart';
import 'package:vikunja_app/domain/entities/task.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';
import 'package:vikunja_app/presentation/manager/calendar_sync.dart';

class _FakeSettingsDatasource implements SettingsDatasource {
  bool syncEnabled;
  String? calendarId;
  Map<int, String> eventMap;

  _FakeSettingsDatasource({
    this.syncEnabled = true,
    this.calendarId = 'cal-1',
    Map<int, String>? eventMap,
  }) : eventMap = eventMap ?? {};

  @override
  Future<bool> getCalendarSyncEnabled() async => syncEnabled;

  @override
  Future<void> setCalendarSyncEnabled(bool value) async {
    syncEnabled = value;
  }

  @override
  Future<String?> getSyncCalendarId() async => calendarId;

  @override
  Future<void> setSyncCalendarId(String? value) async {
    calendarId = value;
  }

  @override
  Future<Map<int, String>> getCalendarEventMap() async => Map.of(eventMap);

  @override
  Future<void> setCalendarEventMap(Map<int, String> value) async {
    eventMap = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTaskRepository implements TaskRepository {
  final List<Task> tasks;
  bool getByFilterStringCalled = false;

  _FakeTaskRepository(this.tasks);

  @override
  Future<Response<List<Task>>> getByFilterString(
    String filterString, [
    Map<String, List<String>>? queryParameters,
  ]) async {
    getByFilterStringCalled = true;
    return SuccessResponse(tasks, 200, {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Fake platform implementation, swapped in via the same
// DeviceCalendarPlusPlatform.instance seam the real android/ios plugins use
// to register themselves. Only createEvent/updateEvent/deleteEvent (the ones
// syncCalendar calls) are implemented; everything else falls through
// noSuchMethod, since a concrete class overriding noSuchMethod is exempt
// from implementing every abstract member.
class _FakeCalendarPlatform extends DeviceCalendarPlusPlatform {
  final List<String> createdTitles = [];
  final List<String> updatedIds = [];
  final List<String> deletedIds = [];
  int _nextId = 0;

  @override
  Future<String> createEvent(
    String? calendarId,
    String title,
    DateTime startDate,
    DateTime endDate,
    bool isAllDay,
    String? description,
    String? location,
    String? url,
    String? timeZone,
    String availability,
    String? recurrenceRule,
    List<int>? reminders,
  ) async {
    createdTitles.add(title);
    return 'event-${_nextId++}';
  }

  @override
  Future<void> updateEvent(
    String eventId, {
    int? timestamp,
    String? title,
    DateTime? startDate,
    DateTime? endDate,
    Patch<String>? description,
    Patch<String>? location,
    Patch<String>? url,
    bool? isAllDay,
    String? timeZone,
    String? availability,
    Patch<List<int>>? reminders,
  }) async {
    updatedIds.add(eventId);
  }

  @override
  Future<void> deleteEvent(String eventId, {int? timestamp}) async {
    deletedIds.add(eventId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Task _task({required int id, required bool done, DateTime? dueDate}) {
  return Task(
    id: id,
    title: 'Task $id',
    done: done,
    dueDate: dueDate,
    createdBy: User(username: 'tester'),
    projectId: 1,
  );
}

void main() {
  late _FakeCalendarPlatform fakePlatform;

  setUp(() {
    fakePlatform = _FakeCalendarPlatform();
    DeviceCalendarPlusPlatform.instance = fakePlatform;
  });

  test('creates events for open tasks with due dates and drops stale ones', () async {
    final dueDate = DateTime.now().add(Duration(days: 1));
    final tasks = [
      _task(id: 1, done: false, dueDate: dueDate),
      _task(id: 2, done: false, dueDate: dueDate),
      _task(id: 3, done: true, dueDate: dueDate),
    ];
    final settings = _FakeSettingsDatasource(
      calendarId: 'cal-1',
      eventMap: {99: 'stale-event'},
    );
    final taskRepository = _FakeTaskRepository(tasks);

    await syncCalendar(taskRepository, settings);

    expect(fakePlatform.createdTitles, unorderedEquals(['Task 1', 'Task 2']));
    expect(fakePlatform.deletedIds, ['stale-event']);
    expect(settings.eventMap.containsKey(99), isFalse);
    expect(settings.eventMap.length, 2);
  });

  test('skips entirely when calendar sync is disabled', () async {
    final settings = _FakeSettingsDatasource(syncEnabled: false);
    final taskRepository = _FakeTaskRepository([]);

    await syncCalendar(taskRepository, settings);

    expect(taskRepository.getByFilterStringCalled, isFalse);
    expect(fakePlatform.createdTitles, isEmpty);
  });
}
