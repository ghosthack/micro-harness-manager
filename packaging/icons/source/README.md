# Icon source

The app icon is a 3D resistor rendered with three.js in headless Chromium.
`scene.js` models and lights it; `build.py` renders it, crops it square and
writes `../micro-harness-manager.{png,ico,icns}` and the app's `app-icon.png`.
See [../README.md](../README.md) for where each file is used.

```sh
npm ci            # three.js
python3 build.py  # needs Node with Playwright's Chromium, and Python with Pillow
```
