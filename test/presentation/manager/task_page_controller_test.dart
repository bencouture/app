import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikunja_app/core/di/repository_provider.dart';
import 'package:vikunja_app/core/network/response.dart';
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/task.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/repositories/project_repository.dart';
import 'package:vikunja_app/domain/repositories/settings_repository.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';
import 'package:vikunja_app/presentation/manager/task_page_controller.dart';

// Regression coverage for the bug class found while debugging calendar sync:
// every task-mutating method here (updateTask/markAsDone/deleteTask/addTask)
// is supposed to trigger syncCalendar(), same as it already triggers
// updateWidget()/scheduleDueNotifications(). Two of them (markAsDone,
// deleteTask) were previously found bypassing that entirely by mutating
// local state directly instead of going through reload(). These tests fail
// if any of the four ever stops calling it again.
//
// Note updateTask/addTask route through reload(), which makes its own,
// separate getByFilterString call (to refresh the visible task list) even
// when syncCalendar isn't involved at all. So a plain "was it called" check
// is not enough for those two -- we assert on calendar_sync.dart's exact
// filter string ("done = false && due_date > 0001-01-01 00:00"), which only
// syncCalendar ever sends (this repo's own page-list fetch sends a bare
// "done = false"). That filter string is itself the fix for the original
// "wrong Vikunja filter syntax" bug, so this doubles as regression coverage
// for that.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

const _calendarSyncFilter = 'done = false && due_date > 0001-01-01 00:00';

class _FakeTaskRepository implements TaskRepository {
  final List<String> filterStringsReceived = [];

  bool get calendarSyncFetchHappened =>
      filterStringsReceived.contains(_calendarSyncFilter);

  @override
  Future<Response<List<Task>>> getByFilterString(
    String filterString, [
    Map<String, List<String>>? queryParameters,
  ]) async {
    filterStringsReceived.add(filterString);
    return SuccessResponse(<Task>[], 200, {});
  }

  @override
  Future<Response<Task>> update(Task task) async =>
      SuccessResponse(task, 200, {});

  @override
  Future delete(int taskId) async => SuccessResponse(null, 200, {});

  @override
  Future<Response<Task>> add(int projectId, Task task) async =>
      SuccessResponse(task, 200, {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProjectRepository implements ProjectRepository {
  @override
  Future<Response<List<Project>>> getAll({int page = 1}) async =>
      SuccessResponse(<Project>[], 200, {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<bool> getLandingPageOnlyDueDateTasks() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Task _task({int id = 1}) => Task(
  id: id,
  title: 'Task $id',
  createdBy: User(username: 'tester'),
  projectId: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTaskRepository taskRepository;

  setUp(() {
    taskRepository = _FakeTaskRepository();

    // Backs every SettingsDatasource read syncCalendar/updateWidget make
    // (calendar_sync.dart builds its own real SettingsDatasource when not
    // given one, same as the app does). "calendar_sync_enabled"/
    // "sync_calendar_id" are set so syncCalendar runs past its guards and
    // reaches the task fetch; every other key (e.g. "refresh_token", which
    // updateWidget checks) returns null so that call short-circuits instead
    // of trying to hit a real, unmocked network client.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
      if (call.method == 'read') {
        final key = (call.arguments as Map)['key'];
        if (key == 'calendar_sync_enabled') return 'true';
        if (key == 'sync_calendar_id') return 'cal-1';
        return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, null);
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        taskRepositoryProvider.overrideWithValue(taskRepository),
        projectRepositoryProvider.overrideWithValue(_FakeProjectRepository()),
        settingsRepositoryProvider.overrideWithValue(
          _FakeSettingsRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // syncCalendar (like updateWidget/scheduleDueNotifications before it) is
  // deliberately fired-and-forgotten by the controller, so give its
  // microtask chain a turn to run before asserting on it.
  Future<void> flushMicrotasks() => Future.delayed(Duration.zero);

  // build() itself runs the same _createPageModel -> syncCalendar path as
  // reload(), so it already sends the calendar-sync filter before any
  // method under test even runs. Flush that initial call to completion and
  // clear the log so each test only sees the fetch its own mutation causes.
  Future<TaskPageController> readyController(
    ProviderContainer container,
  ) async {
    // AutoDispose provider: without an active listener it's torn down and
    // rebuilt (running build()/_getAllFiltered() again) between reads,
    // which would pollute filterStringsReceived on its own. Keep it alive
    // for the container's lifetime so only the method under test triggers
    // further calls.
    container.listen(taskPageControllerProvider, (_, _) {});
    await container.read(taskPageControllerProvider.future);
    await flushMicrotasks();
    taskRepository.filterStringsReceived.clear();
    return container.read(taskPageControllerProvider.notifier);
  }

  test('updateTask triggers a calendar sync', () async {
    final controller = await readyController(createContainer());

    await controller.updateTask(_task());
    await flushMicrotasks();

    expect(taskRepository.calendarSyncFetchHappened, isTrue);
  });

  test('markAsDone triggers a calendar sync', () async {
    final controller = await readyController(createContainer());

    await controller.markAsDone(_task());
    await flushMicrotasks();

    expect(taskRepository.calendarSyncFetchHappened, isTrue);
  });

  test('deleteTask triggers a calendar sync', () async {
    final controller = await readyController(createContainer());

    await controller.deleteTask(1);
    await flushMicrotasks();

    expect(taskRepository.calendarSyncFetchHappened, isTrue);
  });

  test('addTask triggers a calendar sync', () async {
    final controller = await readyController(createContainer());

    await controller.addTask(1, _task());
    await flushMicrotasks();

    expect(taskRepository.calendarSyncFetchHappened, isTrue);
  });
}
