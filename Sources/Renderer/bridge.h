#include <stddef.h>
#include <stdint.h>

// WeatherUI call bridge (arm64 only). Every Swift type the bridge writes is checked against the
// running system before memory is written; a mismatch ends the process with a status line.

// Loads WeatherUI and checks the layouts the bridge relies on. Returns WeatherCore's own
// Location.init(id:name:timeZone:coordinate:lastRefreshDate:searchTitle:searchSubtitle:preciseName:secondaryName:)
// once a Location is known to fit in `locationCapacity` bytes.
const void *weather_frame_load(size_t locationCapacity);
void weather_frame_prepare(uint8_t condition, const void *emptyArray, double date, double cloudCover, double windSpeed,
                           const void *locationValue, const void *timeZone, double latitude, double longitude,
                           double width, double height, double sunrise, double sunset);
const void *weather_frame_view(void);
const void *weather_frame_gradient(void);
int weather_frame_loaded(void);
double weather_frame_sun_elevation(void);
double weather_frame_moon_phase(void);

// Process-level status reporting. The app reads the last "LIVESKY_STATUS {json}" line on stdout.
void livesky_install_crash_handlers(void);
int livesky_conceal_windows(int enabled);
void livesky_conceal_existing_windows(const char *moment);
void livesky_stage(const char *stage);
void livesky_simulate(int incompatible, int crash);
__attribute__((noreturn)) void livesky_fail(const char *check, const char *detail);
