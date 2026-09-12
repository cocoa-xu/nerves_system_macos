#!/bin/bash
set -euo pipefail
trap 'echo "Guest verification failed at line $LINENO" >&2' ERR

test "$(uname -m)" = arm64
test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(id -un)" = "$GUEST_USERNAME"
test "$(dscl -plist . -read "/Users/$GUEST_USERNAME" RealName | plutil -extract dsAttrTypeStandard:RealName.0 raw -o - -)" = "$GUEST_USERNAME"
sudo -n true
test -e /var/db/.AppleSetupDone
test "$(defaults read -g AppleLocale)" = en_US
test "$(defaults read -g AppleLanguages | tr -d '[:space:](),\"')" = en-US
keyboard=$(defaults export com.apple.HIToolbox - | plutil -extract AppleEnabledInputSources.0.'KeyboardLayout Name' raw -)
test "$keyboard" = 'U.S.' || test "$keyboard" = ABC
if pgrep -x 'Setup Assistant' >/dev/null || pgrep -x VoiceOver >/dev/null; then
  echo 'The guest has not completed unattended setup' >&2
  exit 1
fi
printf 'Verified macOS %s (%s), %s, en_US, en-US, %s\n' "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$GUEST_USERNAME" "$keyboard"
