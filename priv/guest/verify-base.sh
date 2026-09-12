set -euo pipefail

test ! -e /opt/nerves
test ! -e /Library/LaunchDaemons/org.nerves.application.plist
echo 'Verified an application-free macOS base'
