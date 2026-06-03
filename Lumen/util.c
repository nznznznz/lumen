// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#include "util.h"
#include <math.h>
#include <pthread.h>

#define LUMEN_LIGHTNESS_LUT_SIZE 8192

static pthread_once_t lightness_lut_once = PTHREAD_ONCE_INIT;
static double red_luminance_lut[256];
static double green_luminance_lut[256];
static double blue_luminance_lut[256];
static double y_to_lightness_lut[LUMEN_LIGHTNESS_LUT_SIZE + 1];

static double srgb_channel_to_linear(double channel)
{
    double normalized = channel / 255.0;
    return (normalized > 0.04045) ? pow((normalized + 0.055) / 1.055, 2.4) : normalized / 12.92;
}

static double y_to_lightness(double y)
{
    double adjusted = (y > 0.008856) ? pow(y, 1.0/3.0) : (7.787 * y) + 16.0/116.0;
    return (116 * adjusted) - 16;
}

static void initialize_lightness_luts(void)
{
    for (int i = 0; i < 256; i++) {
        double linear = srgb_channel_to_linear(i);
        red_luminance_lut[i] = linear * 0.2126;
        green_luminance_lut[i] = linear * 0.7152;
        blue_luminance_lut[i] = linear * 0.0722;
    }

    for (int i = 0; i <= LUMEN_LIGHTNESS_LUT_SIZE; i++) {
        double y = (double)i / (double)LUMEN_LIGHTNESS_LUT_SIZE;
        y_to_lightness_lut[i] = y_to_lightness(y);
    }
}

static int clamp_srgb_index(double value)
{
    if (value <= 0) {
        return 0;
    }
    if (value >= 255) {
        return 255;
    }
    return (int)value;
}

double linear_interpolate(double x0, double y0, double x1, double y1, double xq)
{
    double dydx = (y1 - y0) / (x1 - x0);
    double yq = y0 + dydx * (xq - x0);
    return yq;
}

double clip(double value, double low, double high)
{
    return (value < low) ? (low) : (value > high ? high : value);
}

double srgb_to_lightness(double red, double green, double blue)
{
    pthread_once(&lightness_lut_once, initialize_lightness_luts);

    int r = clamp_srgb_index(red);
    int g = clamp_srgb_index(green);
    int b = clamp_srgb_index(blue);
    double y = red_luminance_lut[r] + green_luminance_lut[g] + blue_luminance_lut[b];
    int index = (int)lround(clip(y, 0, 1) * LUMEN_LIGHTNESS_LUT_SIZE);
    return y_to_lightness_lut[index];
}
