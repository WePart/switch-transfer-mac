# Agent notes

- Setup: `python3.12 -m venv .venv && .venv/bin/pip install -r requirements-build.txt` (Python must have shared libs; libusb from Homebrew).
- Tests: `.venv/bin/python -m unittest -v test_backend`
- Swift typecheck: `swiftc -parse-as-library -typecheck -target arm64-apple-macosx26.0 Sources/*.swift` (typecheck skips init checks; a full `swiftc ... -o /tmp/x` compile catches those).
- Full build (.app + DMG, ad-hoc signed, self-check): `.venv/bin/python build.py ./release` (`--no-dmg` to skip DMG).
- Version lives only in `backend.py` `VERSION`; the app reads it from the bundle Info.plist.
- Swift sources are in `Sources/` (App, Model, MainView, Components, Panels). Keep state in `Model` (`ObservableObject`/`@Published`); avoid `@State`/`@Observable` because plain `swiftc` here cannot load the SwiftUI macro plugin.
- Wrap animations with `motion()` so they respect Reduce Motion.
- Worker/GUI protocol: newline-delimited JSON events on stdout (`boot`, `device`, `state`, `progress`, `file_done`, `log`, `stopped`, `update_error`, `error`, `fatal`). Commands: `start {paths, keep_serving}`, `update {paths}`, `stop`, `probe`, `quit`.
- UI copy is Simplified Chinese.
