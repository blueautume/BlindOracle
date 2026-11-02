#ifndef BLINDORACLE_SKY_H
#define BLINDORACLE_SKY_H
#include "astronomy.h"

typedef struct {
    int status;
    double longitude;
    double latitude;
    double distance;
    double longitude_speed;
} bo_sky_position;

/* Body order: Sun, Moon, Mercury, Venus, Mars, Jupiter, Saturn, Uranus, Neptune, Pluto. */
bo_sky_position bo_sky_geocentric(int body_index, double unix_seconds);
/* Tropical true-equator-of-date ascendant and upper meridian, east-positive longitude. */
int bo_sky_angles(double unix_seconds, double latitude, double longitude, double *ascendant, double *midheaven);
#endif
