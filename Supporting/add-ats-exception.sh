#!/bin/sh
# Adds an App Transport Security exception for the configured server host to
# the built Info.plist when TURAS_SERVER_URL is plain HTTP.
#
# This runs as a build phase because Xcode does not expand build settings in
# Info.plist keys: a source key of "$(TURAS_SERVER_HOST)" stays literal and
# never matches. Values come from Configuration/*.xcconfig.
set -eu

case "${TURAS_SERVER_URL:-}" in
  http://*) ;;
  *) exit 0 ;;
esac

if [ -z "${TURAS_SERVER_HOST:-}" ]; then
  echo "warning: TURAS_SERVER_URL is plain HTTP but TURAS_SERVER_HOST is not set; no ATS exception added"
  exit 0
fi

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
PB=/usr/libexec/PlistBuddy
DOMAIN=":NSAppTransportSecurity:NSExceptionDomains:${TURAS_SERVER_HOST}"

"$PB" -c "Delete :NSAppTransportSecurity" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :NSAppTransportSecurity dict" "$PLIST"
"$PB" -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$PLIST"
"$PB" -c "Add ${DOMAIN} dict" "$PLIST"
"$PB" -c "Add ${DOMAIN}:NSExceptionAllowsInsecureHTTPLoads bool true" "$PLIST"

if [ "${CONFIGURATION:-}" = "Release" ]; then
  echo "warning: Release build allows plain HTTP to ${TURAS_SERVER_HOST}. Serve the API over HTTPS before shipping to the App Store."
fi
