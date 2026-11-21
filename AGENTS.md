# Agent notes

- Setup: `python3.12 -m venv .venv && .venv/bin/pip install -r requirements-build.txt` (Python must have shared libs; libusb from Homebrew).
- Tests: `.venv/bin/python -m unittest -v test_backend`
- Swift typecheck: `swiftc -parse-as-library -typecheck -target arm64-apple-macosx14.0 App.swift`
- Full build (.app + DMG, ad-hoc signed, self-check): `.venv/bin/python build.py ./release` (`--no-dmg` to skip DMG).
- Version lives only in `backend.py` `VERSION`; `App.swift` reads it from the bundle Info.plist.
- Worker/GUI protocol: newline-delimited JSON events on stdout (`boot`, `device`, `state`, `progress`, `file_done`, `log`, `stopped`, `error`, `fatal`).
- UI copy is Simplified Chinese.
