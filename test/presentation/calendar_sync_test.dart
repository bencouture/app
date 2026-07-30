import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikunja_app/core/network/response.dart';
import 'package:vikunja_app/data/data_sources/settings_data_source.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/task.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';
import 'package:vikunja_app/presentation/manager/calendar_sync.dart';

class _FakeSettingsDatasource implements SettingsDatasource {
  bool syncEnabled;
  String? calendarId;
  Map<int, String> eventMap;
  bool syncAllDayTasks;
  AllDayEventDisplay allDayEventDisplay;
  int? eventColor;
  int? doneColorKey;

  _FakeSettingsDatasource({
    this.syncEnabled = true,
    this.calendarId = 'cal-1',
    Map<int, String>? eventMap,
    this.syncAllDayTasks = false,
    this.allDayEventDisplay = AllDayEventDisplay.midnight,
    this.eventColor,
    this.doneColorKey,
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
  Future<bool> getSyncAllDayTasks() async => syncAllDayTasks;

  @override
  Future<void> setSyncAllDayTasks(bool value) async {
    syncAllDayTasks = value;
  }

  @override
  Future<AllDayEventDisplay> getAllDayEventDisplay() async =>
      allDayEventDisplay;

  @override
  Future<void> setAllDayEventDisplay(AllDayEventDisplay value) async {
    allDayEventDisplay = value;
  }

  @override
  Future<int?> getEventColor() async => eventColor;

  @override
  Future<void> setEventColor(int? value) async {
    eventColor = value;
  }

  @override
  Future<int?> getDoneColorKey() async => doneColorKey;

  @override
  Future<void> setDoneColorKey(int? value) async {
    doneColorKey = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTaskRepository implements TaskRepository {
  final List<Task> tasks;
  bool getByFilterStringCalled = false;
  String? filterStringReceived;
  Map<String, List<String>>? queryParametersReceived;
  final List<Task> updatedTasks = [];
  bool updateShouldFail = false;

  _FakeTaskRepository(this.tasks);

  @override
  Future<Response<List<Task>>> getByFilterString(
    String filterString, [
    Map<String, List<String>>? queryParameters,
  ]) async {
    getByFilterStringCalled = true;
    filterStringReceived = filterString;
    queryParametersReceived = queryParameters;
    return SuccessResponse(tasks, 200, {});
  }

  @override
  Future<Response<Task>> update(Task task) async {
    updatedTasks.add(task);
    if (updateShouldFail) {
      return ErrorResponse(400, {}, {'message': 'update failed'});
    }
    return SuccessResponse(task, 200, {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// device_calendar (unlike device_calendar_plus) has no swappable
// platform-interface seam -- it's a single package talking directly over
// its own MethodChannel. Mocked here the same way the package's own test
// suite mocks it (see device_calendar's test/device_calendar_test.dart).
const _channel = MethodChannel('plugins.builttoroam.com/device_calendar');

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> createdTitles;
  late List<Map> createdEvents;
  late List<String> deletedIds;
  // eventId -> colorKey the mocked retrieveEvents call hands back.
  late Map<String, int?> eventColorKeys;
  late List<List<Object?>> retrieveEventsCalls;
  int nextId = 0;

  setUp(() {
    createdTitles = [];
    createdEvents = [];
    deletedIds = [];
    eventColorKeys = {};
    retrieveEventsCalls = [];
    nextId = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'createOrUpdateEvent':
          final args = call.arguments as Map;
          createdTitles.add(args['eventTitle'] as String);
          createdEvents.add(args);
          return 'event-${nextId++}';
        case 'deleteEvent':
          final args = call.arguments as Map;
          deletedIds.add(args['eventId'] as String);
          return true;
        case 'retrieveEvents':
          final args = call.arguments as Map;
          final eventIds = (args['eventIds'] as List?) ?? const [];
          retrieveEventsCalls.add(eventIds.cast<Object?>());
          return jsonEncode(
            eventIds
                .map(
                  (id) => {
                    'eventId': id,
                    'eventColorKey': eventColorKeys[id],
                  },
                )
                .toList(),
          );
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
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
      eventMap: {99: 'stale-event', 3: 'task-3-event'},
    );
    final taskRepository = _FakeTaskRepository(tasks);

    await syncCalendar(taskRepository, settings);

    // Vikunja's filter query language has no "!= null"; a nullable field
    // still matches even a syntactically-valid filter unless
    // filter_include_nulls is explicitly turned off. Getting either of
    // these wrong previously made this fetch return zero tasks silently.
    expect(
      taskRepository.filterStringReceived,
      'done = false && due_date > 0001-01-01 00:00',
    );
    expect(
      taskRepository.queryParametersReceived?['filter_include_nulls'],
      ['false'],
    );

    expect(createdTitles, unorderedEquals(['Task 1', 'Task 2']));
    // Task 3's own event must go too, not just the unrelated stale one --
    // this is what makes completing a task clear its calendar reminder.
    expect(deletedIds, unorderedEquals(['stale-event', 'task-3-event']));
    expect(settings.eventMap.containsKey(99), isFalse);
    expect(settings.eventMap.containsKey(3), isFalse);
    expect(settings.eventMap.length, 2);
  });

  test('skips entirely when calendar sync is disabled', () async {
    final settings = _FakeSettingsDatasource(syncEnabled: false);
    final taskRepository = _FakeTaskRepository([]);

    await syncCalendar(taskRepository, settings);

    expect(taskRepository.getByFilterStringCalled, isFalse);
    expect(createdTitles, isEmpty);
  });

  test('skips no-specific-time tasks unless all-day sync is enabled', () async {
    final dueDate = DateTime.utc(2030, 1, 1); // midnight UTC == no time set
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(syncAllDayTasks: false);

    await syncCalendar(_FakeTaskRepository(tasks), settings);

    expect(createdTitles, isEmpty);
  });

  test('places a no-specific-time task at midnight when requested', () async {
    final dueDate = DateTime.utc(2030, 1, 1);
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(
      syncAllDayTasks: true,
      allDayEventDisplay: AllDayEventDisplay.midnight,
    );

    await syncCalendar(_FakeTaskRepository(tasks), settings);

    expect(createdTitles, ['Task 1']);
    final start = DateTime.fromMillisecondsSinceEpoch(
      createdEvents.single['eventStartDate'] as int,
      isUtc: true,
    );
    expect(start.hour, 0);
    expect(start.minute, 0);
    expect(createdEvents.single['eventAllDay'], isFalse);
  });

  test('places a no-specific-time task at end of day when requested', () async {
    final dueDate = DateTime.utc(2030, 1, 1);
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(
      syncAllDayTasks: true,
      allDayEventDisplay: AllDayEventDisplay.endOfDay,
    );

    await syncCalendar(_FakeTaskRepository(tasks), settings);

    final end = DateTime.fromMillisecondsSinceEpoch(
      createdEvents.single['eventEndDate'] as int,
      isUtc: true,
    );
    expect(end.hour, 23);
    expect(end.minute, 59);
  });

  test('marks a no-specific-time task as an all-day event when requested', () async {
    final dueDate = DateTime.utc(2030, 1, 1);
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(
      syncAllDayTasks: true,
      allDayEventDisplay: AllDayEventDisplay.allDayEvent,
    );

    await syncCalendar(_FakeTaskRepository(tasks), settings);

    expect(createdEvents.single['eventAllDay'], isTrue);
  });

  test('applies the configured event color', () async {
    final dueDate = DateTime.now().add(Duration(days: 1));
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(eventColor: 0xFFFF0000);

    await syncCalendar(_FakeTaskRepository(tasks), settings);

    expect(createdEvents.single['eventColor'], 0xFFFF0000);
  });

  test(
    'marks the task done and drops the event when its color matches the done color',
    () async {
      final dueDate = DateTime.now().add(Duration(days: 1));
      final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
      final settings = _FakeSettingsDatasource(
        eventMap: {1: 'ev-1'},
        doneColorKey: 7,
      );
      eventColorKeys['ev-1'] = 7;
      final taskRepository = _FakeTaskRepository(tasks);

      await syncCalendar(taskRepository, settings);

      expect(taskRepository.updatedTasks, hasLength(1));
      expect(taskRepository.updatedTasks.single.id, 1);
      expect(taskRepository.updatedTasks.single.done, isTrue);
      expect(deletedIds, ['ev-1']);
      expect(settings.eventMap.containsKey(1), isFalse);
      // The event is only ever deleted, never rebuilt, once its color matches.
      expect(createdTitles, isEmpty);
    },
  );

  test(
    'leaves the task open and keeps syncing when the color does not match the done color',
    () async {
      final dueDate = DateTime.now().add(Duration(days: 1));
      final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
      final settings = _FakeSettingsDatasource(
        eventMap: {1: 'ev-1'},
        doneColorKey: 7,
      );
      eventColorKeys['ev-1'] = 3;
      final taskRepository = _FakeTaskRepository(tasks);

      await syncCalendar(taskRepository, settings);

      expect(taskRepository.updatedTasks, isEmpty);
      expect(createdTitles, ['Task 1']);
      expect(settings.eventMap[1], isNotEmpty);
    },
  );

  test('skips the done-color check entirely when no color is configured', () async {
    final dueDate = DateTime.now().add(Duration(days: 1));
    final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
    final settings = _FakeSettingsDatasource(
      eventMap: {1: 'ev-1'},
      doneColorKey: null,
    );
    eventColorKeys['ev-1'] = 7;
    final taskRepository = _FakeTaskRepository(tasks);

    await syncCalendar(taskRepository, settings);

    expect(retrieveEventsCalls, isEmpty);
    expect(taskRepository.updatedTasks, isEmpty);
    expect(createdTitles, ['Task 1']);
  });

  test(
    'keeps retrying next sync when marking the task done fails',
    () async {
      final dueDate = DateTime.now().add(Duration(days: 1));
      final tasks = [_task(id: 1, done: false, dueDate: dueDate)];
      final settings = _FakeSettingsDatasource(
        eventMap: {1: 'ev-1'},
        doneColorKey: 7,
      );
      eventColorKeys['ev-1'] = 7;
      final taskRepository = _FakeTaskRepository(tasks)
        ..updateShouldFail = true;

      await syncCalendar(taskRepository, settings);

      expect(taskRepository.updatedTasks, hasLength(1));
      // The task is still open Vikunja-side, so the event must live on --
      // falls through to the normal sync path instead of being deleted.
      expect(deletedIds, isEmpty);
      expect(createdTitles, ['Task 1']);
    },
  );
}
