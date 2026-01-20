#!/bin/bash

#######################################################
#                   PROJECT PATHS
#  !! MODIFY THESE TO MATCH YOUR PROJECT HIERARCHY !!
#  Paths are relative to the location of this script.
#######################################################

# The path to the folder containing GRDBCustom.xcodeproj:
GRDB_SOURCE_PATH="GRDB"

# The path to your custom "SQLiteLib-USER.xcconfig":
SQLITELIB_XCCONFIG_USER_PATH="CustomSQLiteConfig/SQLiteLib-USER.xcconfig"

# The path to your custom "GRDBCustomSQLite-USER.xcconfig":
CUSTOMSQLITE_XCCONFIG_USER_PATH="CustomSQLiteConfig/GRDBCustomSQLite-USER.xcconfig"

# The path to your custom "GRDBCustomSQLite-USER.h":
CUSTOMSQLITE_H_USER_PATH="CustomSQLiteConfig/GRDBCustomSQLite-USER.h"

# The name of the .framework output file (We usually want GRDB.framework)
FRAMEWORK_NAME="GRDB"

# The directory in which the .framework file will be placed (must be reachable for the Swift Package)
OUTPUT_PATH="Binary"

# Build configuration. Usually Release is fine.
CONFIGURATION="Release"

#######################################################
#
#######################################################

# The path to the GRDBCustom.xcodeproj file
GRDB_PROJECT_PATH="${GRDB_SOURCE_PATH}/GRDBCustom.xcodeproj"

# The scheme that builds GRDBCustom
GRDB_SCHEME_NAME="GRDBCustom"

# Create a temporary build location
BUILD_DIR="$(mktemp -d)/Build"

#######################################################
#
#######################################################

# Helper function to copy over the configuration files
copy_config_file() {
    local source_file="$1"
    local dest_path="$2"
    local full_source="${source_file}"
    local full_dest="${dest_path}"

    if [ ! -f "$full_source" ]; then
        echo "error: Source configuration file missing: $full_source"
        exit 1
    fi

    echo "  Copying ${source_file} to ${dest_path}"
    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$full_dest")"
    # Copy file preserving metadata
    cp -p "$full_source" "$full_dest"
}

#######################################################
# --- Added: detect which platforms to build ----------
#######################################################

# Normalise incoming arguments to lower-case
REQUESTED_PLATFORMS=()
if [ "$#" -eq 0 ]; then
    # If no args: default to *all* supported platforms
    REQUESTED_PLATFORMS=(ios tvos watchos macos catalyst)
else
    for arg in "$@"; do
        REQUESTED_PLATFORMS+=("$(echo "$arg" | tr '[:upper:]' '[:lower:]')")
    done
fi

# Helper to check whether a platform was requested
platform_requested() {
    local needle="$1"
    for p in "${REQUESTED_PLATFORMS[@]}"; do
        if [[ "$p" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

#######################################################
#
#######################################################

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Sync Custom Config Files ---

echo "Syncing custom configuration files..."

# Define source file names and their destination paths within FRAMEWORK_PROJ_DIR
copy_config_file "${SQLITELIB_XCCONFIG_USER_PATH}" "${GRDB_SOURCE_PATH}/SQLiteCustom/src/SQLiteLib-USER.xcconfig"
copy_config_file "${CUSTOMSQLITE_XCCONFIG_USER_PATH}" "${GRDB_SOURCE_PATH}/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig"
copy_config_file "${CUSTOMSQLITE_H_USER_PATH}" "${GRDB_SOURCE_PATH}/SQLiteCustom/GRDBCustomSQLite-USER.h"

echo "✓ Finished syncing configuration files."

# --- End Sync ---

echo "--- Building XCFramework for ${FRAMEWORK_NAME} ---"
echo "Framework Project: ${GRDB_PROJECT_PATH}"
echo "Output Directory: ${OUTPUT_PATH}"
echo "Build Directory: ${BUILD_DIR}"
echo "Configuration: ${CONFIGURATION}"
echo "Requested platforms: ${REQUESTED_PLATFORMS[*]}"

# Ensure output directory exists
mkdir -p "${OUTPUT_PATH}"

# Clean previous output
rm -rf "${OUTPUT_PATH}/${FRAMEWORK_NAME}.xcframework"

# Array that will collect all the -framework parameters for -create-xcframework
XCFRAMEWORK_COMPONENTS=()

#######################################################
# --- Added: platform-specific build helpers ----------
#######################################################
archive_pair() {
    local device_dest="$1"        # e.g. "generic/platform=iOS"
    local sim_dest="$2"           # e.g. "generic/platform=iOS Simulator"
    local base_name="$3"          # e.g. "iphoneos"
    local device_path="${BUILD_DIR}/${FRAMEWORK_NAME}-${CONFIGURATION}-${base_name}.xcarchive"
    local sim_path="${BUILD_DIR}/${FRAMEWORK_NAME}-${CONFIGURATION}-${base_name}sim.xcarchive"

    echo "Archiving for ${base_name} Device..."
    xcodebuild archive \
        -project "${GRDB_PROJECT_PATH}" \
        -scheme "${GRDB_SCHEME_NAME}" \
        -configuration "${CONFIGURATION}" \
        -destination "${device_dest}" \
        -archivePath "${device_path}" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES

    echo "Archiving for ${base_name} Simulator..."
    xcodebuild archive \
        -project "${GRDB_PROJECT_PATH}" \
        -scheme "${GRDB_SCHEME_NAME}" \
        -configuration "${CONFIGURATION}" \
        -destination "${sim_dest}" \
        -archivePath "${sim_path}" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES

    XCFRAMEWORK_COMPONENTS+=("-framework" "${device_path}/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")
    XCFRAMEWORK_COMPONENTS+=("-framework" "${sim_path}/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")
}

archive_single() {
    local dest="$1"              # e.g. "generic/platform=macOS"
    local base_name="$2"         # e.g. "macos"
    local path="${BUILD_DIR}/${FRAMEWORK_NAME}-${CONFIGURATION}-${base_name}.xcarchive"

    echo "Archiving for ${base_name}..."
    xcodebuild archive \
        -project "${GRDB_PROJECT_PATH}" \
        -scheme "${GRDB_SCHEME_NAME}" \
        -configuration "${CONFIGURATION}" \
        -destination "${dest}" \
        -archivePath "${path}" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES

    XCFRAMEWORK_COMPONENTS+=("-framework" "${path}/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")
}

#######################################################
# --- Added: perform builds based on arguments --------
#######################################################

if platform_requested ios; then
    archive_pair "generic/platform=iOS" "generic/platform=iOS Simulator" "iphoneos"
fi

if platform_requested tvos; then
    archive_pair "generic/platform=tvOS" "generic/platform=tvOS Simulator" "tvos"
fi

if platform_requested watchos; then
    archive_pair "generic/platform=watchOS" "generic/platform=watchOS Simulator" "watchos"
fi

if platform_requested macos; then
    archive_single "generic/platform=macOS" "macos"
fi

if platform_requested catalyst; then
    archive_single "generic/platform=macOS,variant=Mac Catalyst" "catalyst"
fi

#######################################################
# --- Create the XCFramework --------------------------
#######################################################

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    "${XCFRAMEWORK_COMPONENTS[@]}" \
    -output "${OUTPUT_PATH}/${FRAMEWORK_NAME}.xcframework"

echo "✓ XCFramework created at: ${OUTPUT_PATH}/${FRAMEWORK_NAME}.xcframework"
echo "--- XCFramework script finished ---"
