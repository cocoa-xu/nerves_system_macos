set -euo pipefail

test ! -e /opt/nerves
test ! -L /opt/nerves
test ! -e /Library/LaunchDaemons/org.nerves.application.plist
test ! -L /Library/LaunchDaemons/org.nerves.application.plist
echo 'Verified an application-free macOS base'
