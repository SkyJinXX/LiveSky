# LiveSky

[中文说明](README.zh-CN.md)

**Turn your Mac's wallpaper into a window.**

LiveSky keeps your wallpaper in sync with the real sky where you are. Dawn or dusk, sun or rain, full moon or crescent: whatever the sky is doing outside your window, your desktop shows the same.

<p align="center">
  <img src="docs/day.jpg" width="49%" alt="Sun behind clouds">
  <img src="docs/sunset.jpg" width="49%" alt="Dusk with a crescent moon">
  <img src="docs/night.jpg" width="49%" alt="Moon and stars on a clear night">
  <img src="docs/rain.jpg" width="49%" alt="Rain">
</p>

None of these are photos or imitations. The sky is drawn by macOS's own weather renderer, the same one the Weather app uses. LiveSky sits in the menu bar and quietly keeps every display and every Space up to date.

## Install

1. Download `LiveSky.zip` from [Releases](https://github.com/SkyJinXX/LiveSky/releases) and unzip it.
2. Drag `LiveSky.app` into your Applications folder. It won't work if you open it straight from Downloads.
3. Open LiveSky. It isn't signed with an Apple Developer ID, so macOS says it can't verify the app. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to LiveSky and confirm.

Then choose your location in the welcome window, and the sky outside appears on your desktop.

## Compatibility

LiveSky needs a Mac with Apple silicon.

| macOS | Status |
| --- | --- |
| 15 Sequoia | ✅ Works (tested on a MacBook Pro with M3 Pro, macOS 15.7.7) |
| 26 Tahoe | ⚠️ Tested only in a virtual machine (26.6.2) |
| 27 | ⚠️ Tested only in a virtual machine (27.0.1) |

In the virtual machines every check passes and the sky's colours match macOS 15, but a virtual machine can't draw the sun, moon or clouds. If you have macOS 26 or 27 on a real Mac, please [open an issue](https://github.com/SkyJinXX/LiveSky/issues) and say how it looks.

LiveSky relies on a private Apple framework, so other versions or a future macOS update may break it. If that happens, it leaves your wallpaper alone and tells you in its menu; please attach the report from **Export Diagnostics…** when you open an issue.

## Build from source

You need Xcode.

```bash
git clone https://github.com/SkyJinXX/LiveSky.git
cd LiveSky
./build.sh
```

This produces `build/LiveSky.app`.

## License

[MIT](LICENSE). The sky is drawn on your Mac by Apple's WeatherUI framework; LiveSky contains no Apple code or artwork. Weather data by [Open-Meteo.com](https://open-meteo.com) ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)).

---

If you like having a window on your desktop, a ⭐ helps other people find LiveSky.
