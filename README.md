## Full source code for the TimeScroll app.

TimeScroll records your screen, makes it searchable, and lets you scroll back through time. Everything stays on your Mac.

**Website**: https://timescroll.muzhen.org/

**Download**: https://github.com/XInTheDark/TimeScrollApp/releases/latest

### Building

Requires macOS 14 or later and Xcode. Open `app/TimeScroll.xcodeproj` and use the `TimeScroll` scheme, or run:

```bash
xcodebuild -project app/TimeScroll.xcodeproj -scheme TimeScroll -configuration Debug -quiet -allowProvisioningUpdates build
```

### Contributing

Pull requests are welcome. See [AGENTS.md](AGENTS.md) for the project layout and the coding and testing standards.

### Notes

This repo stays in sync with app releases — it is automatically updated whenever a new app version is published.
