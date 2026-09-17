# Evide Parent App (Flutter)

Live bus tracking for parents: map-first, all children on one map, a child bar
on top, a bus-details bottom sheet, a notifications inbox, and a 500m proximity
alarm (foreground + background via FCM).

## Setup

You already have Flutter. This ships Dart source + Android manifest only, so
you regenerate the platform folders — but you MUST pass the package name that
matches the Firebase config, or Firebase will crash at startup:

```
cd parent-app
flutter create --org com.example --project-name evide_school_parent .
flutter pub get
flutter run
```

That produces the package name `com.example.evide_school_parent`, which matches
the `google-services.json` already placed in `android/app/`.

> The `google-services.json` is on disk at `android/app/google-services.json`
> but is gitignored (not committed) — keep a safe copy; if you re-clone, drop it
> back in.

If you hit the cross-drive Kotlin cache error (project on P:, SDK on C:),
add these to android/gradle.properties:
```
kotlin.incremental=false
kotlin.compiler.execution.strategy=in-process
```

### Wire up Firebase Gradle plugin (required for push)

After `flutter create`, FCM needs the Google-services Gradle plugin. Easiest is:
```
dart pub global activate flutterfire_cli
flutterfire configure --project=evide-school-parent
```
Or do it manually per the FlutterFire "Android installation" docs (add the
`com.google.gms.google-services` plugin to android/app/build.gradle and the
classpath to android/build.gradle). Without this step the build won't pick up
`google-services.json` and push won't work.

### Mapbox Android SDK downloads token (required to build on Android)

The Mapbox Flutter SDK downloads its native Android library at build time using
a SECRET token (separate from the public `pk.` token in the app). Without it,
the Android build fails with a 401.

1. In your Mapbox account → Tokens → create a token with the **`Downloads:Read`**
   scope (this is a secret `sk.` token).
2. Put it in your GLOBAL gradle properties (NOT in the repo):
   `C:\Users\ASUS\.gradle\gradle.properties` — add the line:
   ```
   MAPBOX_DOWNLOADS_TOKEN=sk.your_secret_downloads_token
   ```
This stays on your machine, is never committed, and Gradle reads it during the
Android build.

## Configuration status

- **Mapbox token** — already wired into `lib/config.dart` (your public token).
- **Firebase** — `google-services.json` already in `android/app/`; just do the
  Gradle plugin step above.
- **Custom alarm sound (optional)** — drop an `alarm.mp3` into
  `android/app/src/main/res/raw/` and (for foreground) add `assets/alarm.mp3`
  + register it in pubspec, then set the sound in `alarm_service.dart` as noted
  in the comments. Without it, the default notification sound is used.

## How a parent gets access

A parent needs a Supabase Auth user AND links to their children:

1. Authentication -> Users -> Add user (parent's email + password). Copy the UID.
2. In the SQL editor:
```sql
-- Create the parent profile
insert into parent_users (auth_user_id, phone)
values ('PARENT-AUTH-UID', '+91XXXXXXXXXX')
returning id;   -- copy this parent id

-- Link to each child (student must already exist, with pickup/drop coords + a bus)
insert into parent_student_links (parent_user_id, student_id)
values ('6b917a45-0331-4bd7-9592-93aa54028e6c', '30f8de8f-ce60-49e0-b671-0e4907fbb768');
```
For the map to show a moving bus, the child's bus needs a GPS device sending
positions, and the child needs pickup/drop coordinates set.

## Required schema

Run migrations 002–005 (in the backend db folder) if you haven't:
attendance, photos, write policies, driver notifications, and **005 device_tokens**
(this app registers its FCM token there).

## What it does

- **Login** (Supabase Auth, email + password).
- **Map** (Mapbox) — all linked children selectable via the top bar; shows the
  selected child's bus (live), school, their stop, and a blue road-following
  route line (drawn by calling Mapbox Directions; falls back to a straight line
  if Directions is unavailable).
- **Live updates** via Supabase Realtime — the bus marker moves as new GPS
  positions arrive.
- **Bottom sheet** — bus number, running status, speed, last-updated time.
- **Notifications inbox** — past alerts from management/driver/system.
- **500m alarm** — foreground plays a sound + local notification; background/
  closed is delivered by FCM on the high-importance alarm channel.

## Tested / not tested

I can't run Flutter or reach your Supabase/Mapbox/Firebase from my build
environment, so I did NOT compile or run this. I wrote it against the current
mapbox_maps_flutter 2.23 / supabase_flutter / firebase_messaging APIs,
verified the Mapbox annotation + camera calls against current docs, ran static
checks (brackets, imports all resolve, colors, package deps match pubspec), and
simplified the camera-fit to avoid a version-fragile SDK call. You run
`flutter run` and we fix any environment-specific issues together. The backend
proximity-detector logic (the "<500m" trigger) WAS tested against your schema.
