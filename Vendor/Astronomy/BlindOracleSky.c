#include "BlindOracleSky.h"
#include <math.h>

static double bo_normalize(double value) {
    double angle = fmod(value, 360.0);
    return angle < 0.0 ? angle + 360.0 : angle;
}
static astro_time_t bo_time(double unix_seconds) {
    /* Astronomy Engine UT days are measured from 2000-01-01 12:00 UTC. */
    return Astronomy_TimeFromDays((unix_seconds - 946728000.0) / 86400.0);
}
static astro_ecliptic_t bo_longitude(astro_body_t body, double unix_seconds) {
    return Astronomy_Ecliptic(Astronomy_GeoVector(body, bo_time(unix_seconds), ABERRATION));
}
bo_sky_position bo_sky_geocentric(int body_index, double unix_seconds) {
    const astro_body_t bodies[] = {BODY_SUN, BODY_MOON, BODY_MERCURY, BODY_VENUS, BODY_MARS,
        BODY_JUPITER, BODY_SATURN, BODY_URANUS, BODY_NEPTUNE, BODY_PLUTO};
    bo_sky_position result = {ASTRO_INVALID_PARAMETER, NAN, NAN, NAN, NAN};
    if (body_index < 0 || body_index >= 10 || !isfinite(unix_seconds)) return result;
    astro_ecliptic_t now = bo_longitude(bodies[body_index], unix_seconds);
    result.status = now.status;
    if (now.status != ASTRO_SUCCESS) return result;
    result.longitude = now.elon;
    result.latitude = now.elat;
    result.distance = Astronomy_VectorLength(now.vec);
    astro_ecliptic_t before = bo_longitude(bodies[body_index], unix_seconds - 43200.0);
    astro_ecliptic_t after = bo_longitude(bodies[body_index], unix_seconds + 43200.0);
    if (before.status == ASTRO_SUCCESS && after.status == ASTRO_SUCCESS)
        result.longitude_speed = bo_normalize(after.elon - before.elon + 180.0) - 180.0;
    return result;
}
int bo_sky_angles(double unix_seconds, double latitude, double longitude, double *ascendant, double *midheaven) {
    if (!ascendant || !midheaven || !isfinite(latitude) || !isfinite(longitude)
        || fabs(latitude) >= 66.0 || fabs(longitude) > 180.0) return ASTRO_INVALID_PARAMETER;
    const double rad = 0.017453292519943295;
    astro_time_t time = bo_time(unix_seconds);
    astro_rotation_t rotation = Astronomy_Rotation_EQD_ECT(&time);
    if (rotation.status != ASTRO_SUCCESS) return rotation.status;
    double cos_e = rotation.rot[1][1];
    double sin_e = rotation.rot[2][1];
    double theta = bo_normalize(Astronomy_SiderealTime(&time) * 15.0 + longitude) * rad;
    double phi = latitude * rad;
    /* Intersection of the true ecliptic and local horizon. Select its eastern end. */
    double vx = cos(phi) * sin(theta) * cos_e + sin(phi) * sin_e;
    double vy = -cos(phi) * cos(theta) * cos_e;
    double ez = -cos(phi) * cos(theta);
    if (-sin(theta) * vx + cos(theta) * vy < 0.0) { vx = -vx; ez = -ez; }
    if (hypot(vx, ez) < 1.0e-12) return ASTRO_NO_CONVERGE;
    *ascendant = bo_normalize(atan2(ez, vx) / rad);
    *midheaven = bo_normalize(atan2(sin(theta), cos(theta) * cos_e) / rad);
    return ASTRO_SUCCESS;
}
