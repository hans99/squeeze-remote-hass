#!/usr/bin/env bash
#
# Build an LMS plugin zip for Assistant.
#
# The archive root is Assistant/ (matches Plugins::Assistant::Plugin) so
# extracting into the LMS Plugins directory yields Plugins/Assistant/.
# The zip filename includes the version from install.xml (required so LMS
# does not reuse a cached older download).
#
# Usage: ./build.sh
#
# Produces: dist/Assistant-<version>.zip and prints SHA1 for repo.xml.
#
set -euo pipefail

cd "$(dirname "$0")"

PLUGIN_NAME="Assistant"
INSTALL_XML="install.xml"
DIST_DIR="dist"

if [[ ! -f "$INSTALL_XML" ]]; then
	echo "ERROR: $INSTALL_XML not found" >&2
	exit 1
fi

VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$INSTALL_XML" | head -1)"
if [[ -z "$VERSION" ]]; then
	echo "ERROR: could not read <version> from $INSTALL_XML" >&2
	exit 1
fi

# Sanity-check module name matches folder we package
MODULE="$(sed -n 's:.*<module>\(.*\)</module>.*:\1:p' "$INSTALL_XML" | head -1)"
if [[ "$MODULE" != "Plugins::${PLUGIN_NAME}::Plugin" ]]; then
	echo "ERROR: install.xml module '$MODULE' does not match Plugins::${PLUGIN_NAME}::Plugin" >&2
	exit 1
fi

ZIP_NAME="${PLUGIN_NAME}-${VERSION}.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lms-assistant-build.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

DEST="${STAGE}/${PLUGIN_NAME}"
mkdir -p "$DEST"

# Plugin payload (flat repo → Assistant/ inside the zip)
cp -R \
	API.pm \
	Handlers.pm \
	Images.pm \
	Mdi.pm \
	Plugin.pm \
	Settings.pm \
	SimpleAsyncWS.pm \
	install.xml \
	strings.txt \
	LICENSE \
	Changelog.md \
	README.md \
	HTML \
	share \
	"$DEST/"

# Drop junk that may have been copied
find "$DEST" \( -name '.DS_Store' -o -name '._*' -o -name '*.swp' \) -delete

(
	cd "$STAGE"
	zip -r "$OLDPWD/$ZIP_PATH" "$PLUGIN_NAME" \
		-x '*.DS_Store' -x '*/.*' >/dev/null
)

if command -v sha1sum >/dev/null 2>&1; then
	SHA="$(sha1sum "$ZIP_PATH" | awk '{print $1}')"
else
	SHA="$(shasum -a 1 "$ZIP_PATH" | awk '{print $1}')"
fi

BYTES="$(wc -c < "$ZIP_PATH" | tr -d ' ')"

echo "Built:   $ZIP_PATH"
echo "Version: $VERSION"
echo "Size:    $BYTES bytes"
echo "SHA1:    $SHA"
echo
echo "Extracts to: ${PLUGIN_NAME}/ (place under LMS Plugins/)"
echo "For repo.xml: <url>…/${ZIP_NAME}</url> and <sha>${SHA}</sha>"
