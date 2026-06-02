// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#ifndef Lumen_Constants_h
#define Lumen_Constants_h

#define STOP (@"Stop")
#define START (@"Start")

#define TELEMETRY_URL (@"https://telemetry.anish.io/api/v1/submit")
#define TELEMETRY_IDENTIFIER (@"lumen-v1")
#define TELEMETRY_RETRIES 5
#define TELEMETRY_RETRY_DELAY 15 // seconds
#define TELEMETRY_SALT (@"com.anishathalye.lumen")
#define TELEMETRY_INTERVAL (1 * 24 * 60 * 60) // seconds

#define DEFAULTS_CALIBRATION_POINTS (@"calibrationPoints")
#define DEFAULTS_DISPLAY_CALIBRATION_POINTS (@"displayCalibrationPoints")
#define DEFAULTS_DISPLAY_OVERLAY_CALIBRATION_POINTS (@"displayOverlayCalibrationPoints")
#define DEFAULTS_CALIBRATION_POINTS_MIGRATED (@"calibrationPointsMigratedToPerDisplay")
#define DEFAULTS_IGNORE_LIST (@"ignoreList")
#define DEFAULTS_DEBUG_PANEL_FRAME (@"debugPanelFrame")
#define DEFAULTS_DEBUG_PANEL_VISIBLE (@"debugPanelVisible")
#define DEFAULTS_SAMPLING_FPS (@"samplingFPS")
#define DEFAULTS_ADAPTIVE_SAMPLING_ENABLED (@"adaptiveSamplingEnabled")
#define DEFAULTS_SAMPLING_PRESETS_MIGRATED (@"samplingPresetsMigratedToFastScale")
#define DEFAULTS_MAXIMUM_DIMMING (@"maximumDimming")

#define NOTIFICATION_IGNORE_LIST_CHANGED (@"notification.ignoreListChanged")

#define LINEAR_SUBSAMPLE (16)
#define FRAME_RATE (4) // int, fps
#define DEBOUNCE_DELAY (1) // float, seconds
#define MIN_X_SPACING (10.0) // absolute difference in L* coordinate
#define CHANGE_NOTICE (0.01) // difference in screen brightness level
#define DEFAULT_BRIGHTNESS (0.5)

#endif
