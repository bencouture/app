/// How multiple no-specific-time tasks due on the same day are scheduled
/// on the synced calendar. Only meaningful with AllDayEventDisplay.midnight
/// -- endOfDay and allDayEvent placements don't stack same-day tasks at one
/// timestamp the way midnight placement does, so sequencing wouldn't change
/// anything there.
enum EventTimingMode { simultaneous, sequential }
