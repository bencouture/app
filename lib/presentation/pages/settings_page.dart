import 'package:collection/collection.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
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
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/entities/version.dart';
import 'package:vikunja_app/l10n/gen/app_localizations.dart';
import 'package:vikunja_app/presentation/manager/settings_controller.dart';
import 'package:vikunja_app/presentation/pages/error_widget.dart';
import 'package:vikunja_app/presentation/pages/loading_widget.dart';
import 'package:vikunja_app/presentation/pages/login/login_page.dart';

// Sentinel dropdown value for "create a new calendar", distinct from any
// real calendar id the platform could hand back.
const _newCalendarSentinel = '__new_vikunja_calendar__';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() {
    return SettingsPageState();
  }
}

class SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController durationTextController = TextEditingController();

  Version? newestVersion;

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
                    final status = await DeviceCalendar.instance
                        .requestPermissions();
                    final granted =
                        status == CalendarPermissionStatus.granted ||
                        status == CalendarPermissionStatus.writeOnly;
                    if (!granted) {
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
                  trailing: FutureBuilder<List<Calendar>>(
                    future: DeviceCalendar.instance.listCalendars(),
                    builder: (context, snapshot) {
                      final calendars = (snapshot.data ?? [])
                          .where((c) => !c.readOnly)
                          .toList();
                      return DropdownButton<String>(
                        value: settings.syncCalendarId,
                        hint: Text("Select calendar"),
                        items: [
                          ...calendars.map(
                            (c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(c.name),
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
                            calendarId = await DeviceCalendar.instance
                                .createCalendar(name: "Vikunja");
                          }
                          ref
                              .read(settingsControllerProvider.notifier)
                              .setSyncCalendarId(calendarId);
                        },
                      );
                    },
                  ),
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
