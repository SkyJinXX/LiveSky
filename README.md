# LiveSky

[中文说明](README.zh-CN.md)

LiveSky keeps your Mac's desktop picture identical to the sky in the Weather app: the same time of day, the same weather and the same moon phase. It lives in the menu bar and updates the wallpaper quietly in the background.

The sky is not a photo or an imitation. LiveSky asks macOS's own weather renderer (WeatherUI, the framework behind the Weather app) to draw one frame for your location, and sets that frame as the wallpaper on every display and every Space.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia. Verified on macOS 15.7.7 (24G720). On other versions LiveSky still tries, and stops safely if something doesn't match (see [Other macOS versions](#other-macos-versions)).
- An internet connection for the weather data.

## Install

1. Download `LiveSky.zip` and double-click it to unzip (Safari usually unzips it for you). You get a `LiveSky` folder with the app and this README.
2. **Drag `LiveSky.app` into the Applications folder.** macOS runs downloaded apps that were not moved from a temporary, read-only location, and LiveSky cannot work from there.
3. Double-click LiveSky. Because LiveSky is not signed with an Apple Developer ID, macOS says *Apple could not verify "LiveSky" is free of malware*. Click **Done**.
4. Open **System Settings → Privacy & Security** and scroll down to **Security**. Next to *"LiveSky" was blocked to protect your Mac*, click **Open Anyway**, then confirm with **Open Anyway** and your password or Touch ID.

You only do this once. On macOS 15, Control-clicking the app and choosing Open no longer skips this step.

## First launch

A welcome window asks where the weather should come from:

- **Use my location (approximate)**: macOS asks once for permission to use your location.
- **Choose a city**: type a city name and pick it from the list.

You can also choose how often to update (5, 10, 15, 30 or 60 minutes; 15 by default) and whether LiveSky opens at login (on by default). Click **Start**. LiveSky first remembers the current wallpaper of each display, then sets the first sky. macOS may show a notification that LiveSky was added as a login item.

## The menu

Click the weather icon in the menu bar:

- The status at the top: place, weather, temperature and the time of the last update, or what went wrong.
- **Update Now** fetches the weather and redraws the sky right away.
- **Pause** / **Resume** stops and restarts the automatic updates.
- **Restore Original Wallpaper** puts back the wallpaper you had before LiveSky, on all Spaces, and pauses updates. Choose Resume to start again.
- **Settings…** changes the location, the interval and launch at login.
- **Quit** stops LiveSky. The current sky stays as your wallpaper.

LiveSky also updates right away after the Mac wakes and when displays are connected or rearranged, and it skips updates while the displays are asleep. Nothing appears on screen while a frame is rendered.

Can't find the icon? Menu bar managers such as Bartender hide new icons, and on MacBooks with a notch icons can end up behind the notch. Double-click LiveSky.app again to open its settings.

## Privacy and permissions

- **Location is the only permission LiveSky asks for, and it is optional.** It is requested only if you choose *Use my location*, and LiveSky asks for approximate accuracy only. Choosing a city needs no permission.
- **Weather data comes from [Open-Meteo](https://open-meteo.com)** (free, no account). LiveSky sends Open-Meteo the coordinates of your location or of the chosen city. City search sends the text you type to Open-Meteo's geocoding service.
- With *Use my location*, the city name shown in the menu is looked up with Apple's geocoder.
- Nothing else leaves your Mac. There are no analytics.
- LiveSky keeps its files in `~/Library/Application Support/LiveSky`. If macOS refuses the login item, LiveSky falls back to `~/Library/LaunchAgents/local.livesky.LiveSky.plist`.
- After you have approved LiveSky, it removes the download quarantine flag from its own embedded renderer, so macOS doesn't ask about the helper again.

## Other macOS versions

WeatherUI is a private Apple framework, so any macOS update can change it. LiveSky is built to fail safely:

- The renderer runs as a separate process. Before it writes any memory, it checks that every WeatherUI function it needs exists and that the Swift types it fills in still have the verified sizes and field offsets.
- LiveSky then checks the picture: the expected size, not transparent, not a single flat colour.
- If anything fails, **your wallpaper is left unchanged**, the menu shows *This macOS version isn't supported yet*, and **Export Diagnostics…** saves a report (macOS build, the failing check, the renderer's output) you can send along with a bug report.
- After a failure LiveSky does not try again on the same macOS build until you press **Retry**. After a macOS update it tries again by itself, at most once a day.
- When it works on a build that hasn't been verified yet, it runs quietly as usual; only the version line at the bottom of the settings window says "not yet verified".

## Good to know

- The weather comes from Open-Meteo, not Apple Weather, so the sky can occasionally differ from what the Weather app shows.
- Frames are rendered at 1826 × 1344 points and scaled to each display, because larger renders lose the sun, moon and light effects. On 4K and 5K displays the sky is slightly softer than native resolution.
- LiveSky has no Developer ID signature, so macOS treats each new version as a new app: after you replace LiveSky with a newer version, it asks for location permission again (only if you use *Use my location*).
- Restore puts back the picture file macOS reports for each display. Dynamic and Aerial wallpapers may need to be chosen again in System Settings.
- Other apps that change the wallpaper on a schedule will fight with LiveSky. Turn them off while you use LiveSky.

## Uninstall

1. Choose **Restore Original Wallpaper** if you want your old wallpaper back.
2. Turn off **Open at login** in LiveSky's settings, then choose **Quit**.
3. Delete LiveSky.app and the folder `~/Library/Application Support/LiveSky`.

## Building from source

You need Xcode (for the Mac Catalyst SDK). Run:

```bash
./build.sh
```

It writes `build/LiveSky.app` and `dist/LiveSky.zip`, ad-hoc signed.

| Path | Contents |
| --- | --- |
| `Sources/LiveSky` | The menu bar app: scheduling, Open-Meteo, location, compositing, wallpaper, settings |
| `Sources/Renderer` | `LiveSkyRenderer.app`, the Mac Catalyst helper with the WeatherUI bridge (arm64) |
| `Resources` | Info.plist files, English and Simplified Chinese strings, the icon |
| `tools` | Verification tools: on-screen wallpaper check, image diff, focus watcher, icon generator |

`LiveSky.app/Contents/MacOS/LiveSky --ctl help` lists debug commands that drive the running app (update, pause, restore, simulated failures and more).
