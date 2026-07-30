import 'dart:async';

import 'package:collection/collection.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vikunja_app/core/di/locale_provider.dart';
import 'package:vikunja_app/core/di/network_provider.dart';
import 'package:vikunja_app/core/di/notification_provider.dart';
import 'package:vikunja_app/core/di/repository_provider.dart';
import 'package:vikunja_app/core/theming/theme_mode.dart';
import 'package:vikunja_app/core/utils/language_autonyms.dart';
import 'package:vikunja_app/core/utils/user_extensions.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/event_timing_mode.dart';
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/entities/version.dart';
import 'package:vikunja_app/l10n/gen/app_localizations.dart';
import 'package:vikunja_app/presentation/manager/calendar_sync.dart';
import 'package:vikunja_app/presentation/manager/settings_controller.dart';
import 'package:vikunja_app/presentation/pages/error_widget.dart';
import 'package:vikunja_app/presentation/pages/loading_widget.dart';
import 'package:vikunja_app/presentation/pages/login/login_page.dart';

// Sentinel dropdown value for "create a new calendar", distinct from any
// real calendar id the platform could hand back.
const _newCalendarSentinel = '__new_vikunja_calendar__';

const _allDayDisplayLabels = {
  AllDayEventDisplay.midnight: 'At midnight (00:00)',
  AllDayEventDisplay.endOfDay: 'At end of day (23:59)',
  AllDayEventDisplay.allDayEvent: 'As an all-day event',
};

const _eventTimingLabels = {
  EventTimingMode.simultaneous: 'All at the same time',
  EventTimingMode.sequential: 'Sequential (15 minutes apart)',
};

// The event color palette lives in the calendar app, not Vikunja -- refetch
// periodically while this page is open so a color added/renamed/removed
// there shows up without the user needing to leave and reopen Settings.
const _colorRefreshInterval = Duration(seconds: 30);

// Google event colors, keyed by RGB (not colorKey -- Google's June 2026
// update unified event colors with the older 24-color calendar palette, and
// also added a full custom RGB picker with no published names, so colorKey
// numbering is no longer a reliable name key). CalendarContract.Colors and
// the Calendar API only return raw RGB, never a name, so this table is
// hardcoded from Google's documented "Modern" calendar color set. Anything
// not in this table (a custom RGB pick) has no known name and falls back to
// "Color N".
const _googleEventColorNames = {
  0xFF795548: "Cocoa",
  0xFFE67C73: "Flamingo",
  0xFFD50000: "Tomato",
  0xFFF4511E: "Tangerine",
  0xFFEF6C00: "Pumpkin",
  0xFFF09300: "Mango",
  0xFF009688: "Eucalyptus",
  0xFF0B8043: "Basil",
  0xFF7CB342: "Pistachio",
  0xFFC0CA33: "Avocado",
  0xFFE4C441: "Citron",
  0xFFF6BF26: "Banana",
  0xFF33B679: "Sage",
  0xFF039BE5: "Peacock",
  0xFF4285F4: "Cobalt",
  0xFF3F51B5: "Blueberry",
  0xFF7986CB: "Lavender",
  0xFFB39DDB: "Wisteria",
  0xFF616161: "Graphite",
  0xFFA79B8E: "Birch",
  0xFFAD1457: "Radicchio",
  0xFFD81B60: "Cherry Blossom",
  0xFF8E24AA: "Grape",
  0xFF9E69AF: "Amethyst",
};

String _eventColorLabel(EventColor c) {
  final rgb = c.color | 0xFF000000;
  return _googleEventColorNames[rgb] ?? "Color ${c.colorKey}";
}

// The only real source of "what colors can an event be" -- device_calendar
// has no platform-independent list. retrieveEventColors needs the actual
// Calendar (for its accountName), not just the id syncCalendarId stores, and
// only returns entries for Google-synced Android calendars: null on iOS
// (EventKit has no per-event color at all) or [] for a local calendar with
// no account color table. There's no honest raw-color fallback for those
// cases -- a hardcoded swatch value doesn't correspond to any real palette
// slot, so Google Calendar just ignores it on the next sync.
Future<List<EventColor>> _retrieveEventColorOptions(String? calendarId) async {
  if (calendarId == null) return [];
  final calendarsResult = await DeviceCalendarPlugin().retrieveCalendars();
  final calendar = (calendarsResult.data ?? const [])
      .firstWhereOrNull((c) => c.id == calendarId);
  if (calendar == null) return [];
  return await DeviceCalendarPlugin().retrieveEventColors(calendar) ?? [];
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() {
    return SettingsPageState();
  }
}

class SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController durationTextController = TextEditingController();
  late final Timer _colorRefreshTimer;

  Version? newestVersion;

  @override
  void initState() {
    super.initState();
    _colorRefreshTimer = Timer.periodic(_colorRefreshInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _colorRefreshTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);

    final l10n = AppLocalizations.of(context);
    final overrideLocale = ref.watch(localeOverrideProvider).asData?.value;
    final resolvedLocale = Localizations.localeOf(context);
    final platformLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final bool isSystemSelected = overrideLocale == null;
    final bool isFallback =
        isSystemSelected &&
        platformLocale.languageCode != resolvedLocale.languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: settings.when(
        data: (settings) {
          durationTextController.text = settings.refreshInterval.toString();
          // Called once per build and shared by both pickers below, so
          // "Event color" and "Mark done via color" always see the exact
          // same resolved list instead of two independent plugin round-trips
          // that happen to usually agree.
          final eventColorOptionsFuture = _retrieveEventColorOptions(
            settings.syncCalendarId,
          );

          return ListView(
            children: [
              _buildUserHeader(ref, settings.user, settings.projects, context),
              Divider(),
              ListTile(
                title: Text(l10n.theme),
                trailing: DropdownButton<FlutterThemeMode>(
                  items: [
                    DropdownMenuItem(
                      value: FlutterThemeMode.system,
                      child: Text(l10n.system),
                    ),
                    DropdownMenuItem(
                      value: FlutterThemeMode.light,
                      child: Text(l10n.light),
                    ),
                    DropdownMenuItem(
                      value: FlutterThemeMode.dark,
                      child: Text(l10n.dark),
                    ),
                  ],
                  value: settings.themeMode,
                  onChanged: (FlutterThemeMode? value) {
                    ref
                        .read(settingsControllerProvider.notifier)
                        .setThemeMode(value ?? FlutterThemeMode.system);
                  },
                ),
              ),
              ListTile(
                title: Text(l10n.language),
                subtitle: isFallback
                    ? Text(
                        'System language (${platformLocale.languageCode}${platformLocale.countryCode != null ? '-${platformLocale.countryCode}' : ''}) not supported. Using ${languageAutonym(resolvedLocale)}.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      )
                    : null,
                trailing: DropdownButton<Locale?>(
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.systemLanguage),
                    ),
                    ...AppLocalizations.supportedLocales.map(
                      (loc) => DropdownMenuItem(
                        value: loc,
                        child: Text(languageAutonym(loc)),
                      ),
                    ),
                  ],
                  value: overrideLocale,
                  onChanged: (Locale? value) {
                    ref.read(localeOverrideProvider.notifier).setLocale(value);
                  },
                ),
              ),
              SwitchListTile(
                title: Text(l10n.dynamicColors),
                value: settings.dynamicColors,
                onChanged: (bool? value) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setDynamicColors(value ?? false);
                },
              ),
              Divider(),
              SwitchListTile(
                title: Text("Sync tasks to calendar"),
                subtitle: Text(
                  "Adds a calendar event for every open task with a due date",
                ),
                value: settings.calendarSyncEnabled,
                onChanged: (bool? value) async {
                  if (value == true) {
                    // First-ever calendar-plugin call: this is also the
                    // first moment the OS permission dialog can appear.
                    // Full access (not write-only): this settings page
                    // needs to list existing calendars for the picker
                    // below, which needs read access.
                    final result = await DeviceCalendarPlugin()
                        .requestPermissions();
                    if (result.data != true) {
                      // Leave the switch off, don't retry silently.
                      return;
                    }
                  }
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setCalendarSyncEnabled(value ?? false);
                },
              ),
              if (settings.calendarSyncEnabled)
                ListTile(
                  title: Text("Sync calendar"),
                  trailing: FutureBuilder(
                    future: DeviceCalendarPlugin().retrieveCalendars(),
                    builder: (context, snapshot) {
                      final calendars = (snapshot.data?.data ?? const [])
                          .where((c) => c.isReadOnly != true)
                          .toList();
                      // Until retrieveCalendars() resolves, calendars is
                      // still empty -- passing a value DropdownButton can't
                      // find among its items throws an assertion error, so
                      // fall back to the hint for that one frame.
                      final knownCalendarId = calendars.any(
                        (c) => c.id == settings.syncCalendarId,
                      );
                      return DropdownButton<String>(
                        value: knownCalendarId ? settings.syncCalendarId : null,
                        hint: Text("Select calendar"),
                        items: [
                          ...calendars.map(
                            (c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(c.name ?? c.id ?? ''),
                            ),
                          ),
                          DropdownMenuItem(
                            value: _newCalendarSentinel,
                            child: Text("Vikunja (new calendar)"),
                          ),
                        ],
                        onChanged: (value) async {
                          if (value == null) return;
                          var calendarId = value;
                          if (value == _newCalendarSentinel) {
                            final created = await DeviceCalendarPlugin()
                                .createCalendar("Vikunja");
                            if (!created.isSuccess) return;
                            calendarId = created.data!;
                          }
                          await ref
                              .read(settingsControllerProvider.notifier)
                              .setSyncCalendarId(calendarId);
                          await syncCalendar(ref.read(taskRepositoryProvider));
                        },
                      );
                    },
                  ),
                ),
              if (settings.calendarSyncEnabled)
                SwitchListTile(
                  title: Text("Sync all-day tasks"),
                  subtitle: Text(
                    "Also sync tasks due on a day but with no specific time",
                  ),
                  value: settings.syncAllDayTasks,
                  onChanged: (bool? value) async {
                    await ref
                        .read(settingsControllerProvider.notifier)
                        .setSyncAllDayTasks(value ?? false);
                    await syncCalendar(ref.read(taskRepositoryProvider));
                  },
                ),
              if (settings.calendarSyncEnabled && settings.syncAllDayTasks)
                ListTile(
                  title: Text("Show all-day tasks as"),
                  trailing: DropdownButton<AllDayEventDisplay>(
                    value: settings.allDayEventDisplay,
                    items: _allDayDisplayLabels.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) async {
                      if (value == null) return;
                      await ref
                          .read(settingsControllerProvider.notifier)
                          .setAllDayEventDisplay(value);
                      await syncCalendar(ref.read(taskRepositoryProvider));
                    },
                  ),
                ),
              if (settings.calendarSyncEnabled &&
                  settings.syncAllDayTasks &&
                  (settings.allDayEventDisplay == AllDayEventDisplay.midnight ||
                      settings.allDayEventDisplay == AllDayEventDisplay.endOfDay))
                ListTile(
                  title: Text("Event creation"),
                  subtitle: Text(
                    settings.allDayEventDisplay == AllDayEventDisplay.midnight
                        ? "How same-day tasks are spaced out at midnight"
                        : "How same-day tasks are spaced out at end of day",
                  ),
                  trailing: DropdownButton<EventTimingMode>(
                    value: settings.eventTimingMode,
                    items: _eventTimingLabels.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) async {
                      if (value == null) return;
                      await ref
                          .read(settingsControllerProvider.notifier)
                          .setEventTimingMode(value);
                      await syncCalendar(ref.read(taskRepositoryProvider));
                    },
                  ),
                ),
              if (settings.calendarSyncEnabled)
                FutureBuilder(
                  future: eventColorOptionsFuture,
                  builder: (context, snapshot) {
                    // No idiomatic reason to show a picker that can only
                    // ever offer "Default" -- hide the row entirely rather
                    // than expose a dead control (iOS, a local calendar
                    // with no color table, or still loading).
                    final colors = snapshot.data;
                    if (colors == null || colors.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    // The configured eventColorKey may not appear in a
                    // freshly refetched palette (color renamed/removed in
                    // the calendar app) -- DropdownButton asserts if value
                    // isn't among items, so fall back to null rather than
                    // crash.
                    final knownEventColorKey =
                        settings.eventColorKey == null ||
                        colors.any((c) => c.colorKey == settings.eventColorKey);
                    return ListTile(
                      title: Text("Event color"),
                      trailing: DropdownButton<int?>(
                        value: knownEventColorKey ? settings.eventColorKey : null,
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text("Default"),
                          ),
                          ...colors.map(
                            (c) => DropdownMenuItem(
                              value: c.colorKey,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: Color(c.color),
                                      border: Border.all(
                                        color: Theme.of(context).dividerColor,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Text(_eventColorLabel(c)),
                                ],
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) async {
                          final selection = value == null
                              ? null
                              : colors.firstWhereOrNull(
                                  (c) => c.colorKey == value,
                                );
                          await ref
                              .read(settingsControllerProvider.notifier)
                              .setEventColor(selection);
                          await syncCalendar(ref.read(taskRepositoryProvider));
                        },
                      ),
                    );
                  },
                ),
              if (settings.calendarSyncEnabled)
                FutureBuilder(
                  future: eventColorOptionsFuture,
                  builder: (context, snapshot) {
                    final colors = snapshot.data;
                    if (colors == null || colors.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final knownDoneColorKey =
                        settings.doneColorKey == null ||
                        colors.any((c) => c.colorKey == settings.doneColorKey);
                    return ListTile(
                      title: Text("Mark done via color"),
                      subtitle: Text(
                        "Setting a synced event to this color closes the "
                        "task and removes the event.",
                      ),
                      trailing: DropdownButton<int?>(
                        value: knownDoneColorKey ? settings.doneColorKey : null,
                        items: [
                          DropdownMenuItem(value: null, child: Text("None")),
                          ...colors.map(
                            (c) => DropdownMenuItem(
                              value: c.colorKey,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: Color(c.color),
                                      border: Border.all(
                                        color: Theme.of(context).dividerColor,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Text(_eventColorLabel(c)),
                                ],
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) async {
                          await ref
                              .read(settingsControllerProvider.notifier)
                              .setDoneColorKey(value);
                        },
                      ),
                    );
                  },
                ),
              Divider(),
              CheckboxListTile(
                title: Text(l10n.ignoreCertificates),
                value: settings.ignoreCertificates,
                onChanged: (value) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setIgnoreCertificates(value ?? false);
                },
              ),
              Divider(),
              CheckboxListTile(
                title: Text(l10n.enableSentry),
                subtitle: Text(l10n.sentryHelp),
                value: settings.sentryEnabled,
                onChanged: (value) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setSentryEnabled(value ?? false);
                },
              ),
              Divider(),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Flexible(
                      child: TextField(
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        keyboardType: TextInputType.number,
                        controller: durationTextController,
                        decoration: InputDecoration(
                          labelText: l10n.backgroundRefreshInterval,
                          helperText: l10n.noLimitHelper,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(settingsControllerProvider.notifier)
                            .setRefreshInterval(
                              int.tryParse(durationTextController.value.text) ??
                                  0,
                            );
                      },
                      child: Text(l10n.save),
                    ),
                  ],
                ),
              ),
              Divider(),
              CheckboxListTile(
                title: Text(l10n.getVersionNotifications),
                value: settings.versionNotifications,
                onChanged: (value) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setVersionNotifications(value ?? false);
                },
              ),
              TextButton(
                onPressed: () async {
                  var notifGranted = await Permission.notification.isGranted;
                  if (notifGranted) {
                    ref.read(notificationProvider)?.sendTestNotification();
                  } else {
                    var status = await Permission.notification.request();
                    if (status.isGranted) {
                      ref.read(notificationProvider)?.sendTestNotification();
                    } else if (status.isPermanentlyDenied && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.noNotificationPermission)),
                      );
                    }
                  }
                },
                child: Text(l10n.sendTestNotification),
              ),
              TextButton(
                onPressed: () async {
                  var newestVersion = await ref
                      .read(versionRepositoryProvider)
                      .getLatestVersionTag();
                  if (newestVersion == null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Couldn't get latest version!")),
                    );
                  } else {
                    setState(() {
                      this.newestVersion = newestVersion;
                    });
                  }
                },
                child: Text(l10n.checkForLatestVersion),
              ),
              Text(
                settings.currentVersion != null
                    ? l10n.currentVersionPrefix(
                        settings.currentVersion.toString(),
                      )
                    : l10n.currentVersionUnknown,
              ),
              Text(
                newestVersion != null
                    ? l10n.latestVersionPrefix(newestVersion.toString())
                    : "",
              ),
              Divider(),
              TextButton(
                onPressed: () {
                  ref.read(settingsRepositoryProvider).saveServer(null);
                  ref.read(settingsRepositoryProvider).saveUserToken(null);
                  ref.read(settingsRepositoryProvider).saveRefreshToken(null);

                  Navigator.of(context).popUntil((route) => route.isFirst);
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (buildContext) => LoginPage()),
                  );
                },
                child: Text(l10n.logout),
              ),
            ],
          );
        },
        error: (err, _) => VikunjaErrorWidget(
          error: err,
          onRetry: () => ref.invalidate(settingsControllerProvider),
        ),
        loading: () => const LoadingWidget(),
      ),
    );
  }

  Widget _buildUserHeader(
    WidgetRef ref,
    User user,
    List<Project> projects,
    BuildContext context,
  ) {
    return Column(
      children: [
        UserAccountsDrawerHeader(
          accountName: Text(
            user.displayName,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
          accountEmail: Text(
            user.username,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
          currentAccountPicture: FutureBuilder(
            future: ref.read(clientProviderProvider).getHeaders(),
            builder: (context, asyncSnapshot) {
              if (asyncSnapshot.hasData && asyncSnapshot.data != null) {
                return CircleAvatar(
                  backgroundImage: user.username != ""
                      ? NetworkImage(
                          user.avatarUrl(
                            ref.read(clientProviderProvider).apiBase,
                          ),
                          headers: asyncSnapshot.data,
                        )
                      : null,
                );
              } else {
                return CircleAvatar();
              }
            },
          ),
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage("assets/graphics/hypnotize.png"),
              repeat: ImageRepeat.repeat,
              colorFilter: ColorFilter.mode(
                Theme.of(context).colorScheme.secondaryContainer,
                BlendMode.multiply,
              ),
            ),
          ),
        ),
        ListTile(
          title: Text(AppLocalizations.of(context).defaultProject),
          trailing: DropdownButton<int>(
            items: [
              DropdownMenuItem(
                value: 0,
                child: Text(AppLocalizations.of(context).none),
              ),
              ...projects.map(
                (e) => DropdownMenuItem(value: e.id, child: Text(e.title)),
              ),
            ],
            value:
                projects.firstWhereOrNull(
                      (element) =>
                          element.id == user.settings?.defaultProjectId,
                    ) !=
                    null
                ? user.settings?.defaultProjectId
                : 0,
            onChanged: (int? value) {
              if (value != null && user.settings != null) {
                ref
                    .read(settingsControllerProvider.notifier)
                    .setDefaultProject(value);
              }
            },
          ),
        ),
      ],
    );
  }
}
