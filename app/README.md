# K POS Flutter client

Android-first cashier/admin client for K POS. It uses Riverpod, Dio,
GoRouter and SQLite. The SQLite cache supports catalogue browsing, open-order
editing and basic checkout when the API is unreachable.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The debug APK is written to
`build/app/outputs/flutter-apk/app-debug.apk`. The backend download copy lives
at `../backend/static/downloads/kts-pos.apk`.

See [`../SYSTEM_OVERVIEW.md`](../SYSTEM_OVERVIEW.md) for the complete runtime
architecture, offline guarantees and deployment order.
