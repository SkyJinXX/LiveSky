# LiveSky

[中文说明](README.zh-CN.md)

**Turn your Mac's wallpaper into a window.**

LiveSky keeps your wallpaper in sync with the real sky where you are, and keeps it moving: rain falls, snow drifts, clouds roll by and stars twinkle, just like in the Weather app. Dawn or dusk, sun or rain, full moon or crescent: whatever the sky is doing outside your window, your desktop shows the same.

<p align="center">
  <img src="docs/day.jpg" width="49%" alt="Sun behind clouds">
  <img src="docs/sunset.jpg" width="49%" alt="Dusk with a crescent moon">
  <img src="docs/night.jpg" width="49%" alt="Moon and stars on a clear night">
  <img src="docs/rain.jpg" width="49%" alt="Rain">
</p>

None of these are photos, videos or imitations. The sky is drawn and animated by macOS's own weather renderer, the same one the Weather app uses. LiveSky sits in the menu bar and quietly keeps every display and every Space up to date.

## Install

1. Download `LiveSky.zip` from [Releases](https://github.com/SkyJinXX/LiveSky/releases) and unzip it.
2. Drag `LiveSky.app` into your Applications folder. It won't work if you open it straight from Downloads.
3. Open LiveSky. It isn't signed with an Apple Developer ID, so macOS says it can't verify the app. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to LiveSky and confirm.

Then choose your location in the welcome window, and the sky outside appears on your desktop.

## Live sky

LiveSky plays Apple's animation in a window behind your desktop icons, on top of a still wallpaper of the same sky. Every few minutes both move on to the latest weather, time of day and moon.

- **Live Sky** in the menu turns the animation on or off.
- Below it you set a frame-rate limit for when your Mac is plugged in and for when it runs on battery: Still, 12, 24, 30 or 60 fps (60 and 12 to begin with). The weather decides the actual rate: 24 fps for clear skies, 30 for clouds and fog, 60 for rain, snow and storms. Low Power Mode uses the battery setting.
- The animation pauses by itself while windows cover most of the desktop, while the screen is locked and while the Mac is hot, so most of the time it costs nothing. While it moves it uses about as much power as having the Weather app open: a few tenths of a watt on a MacBook Pro with M3 Pro.
- To tell whether the desktop is covered, LiveSky reads the positions and sizes of the windows on screen, not their titles or contents. This needs no permission.
- The lock screen shows the still wallpaper. In Activity Monitor the animation appears as LiveSky Renderer, one per display.

## Compatibility

LiveSky needs a Mac with Apple silicon.

| macOS | Status |
| --- | --- |
| 15 Sequoia | ✅ Works (tested on a MacBook Pro with M3 Pro, macOS 15.7.7) |
| 26 Tahoe | ⚠️ Tested only in a virtual machine (26.6.2) |
| 27 | ⚠️ Tested only in a virtual machine (27.0.1) |

In the virtual machines every check passes, the sky's colours match macOS 15, and the live sky starts, keeps to its frame-rate limit and pauses, but a virtual machine can't draw the sun, moon, clouds or stars. If you have macOS 26 or 27 on a real Mac, please [open an issue](https://github.com/SkyJinXX/LiveSky/issues) and say how it looks.

LiveSky relies on a private Apple framework, so other versions or a future macOS update may break it. If that happens, it leaves your wallpaper alone, or keeps the sky still if the animation can't be controlled, and tells you in its menu; please attach the report from **Export Diagnostics…** when you open an issue.

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
