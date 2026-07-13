#!/usr/bin/env bash
#
# release-testflight.sh — archive, export, validate, and upload an iOS app to
# TestFlight via xcodebuild + xcrun altool. This is the fastlane-free path;
# use it when you don't want to install a Ruby toolchain or fastlane.
#
# Pipeline:
#   1. Resolve Swift packages
#   2. Clean archive the target scheme (Release)
#   3. Export a signed App Store .ipa using Templates/ExportOptions.plist
#   4. Validate, then upload the .ipa to App Store Connect via an API key
#
# Authentication uses an App Store Connect API key (.p8). It is never stored
# in the repo — point at it via env vars, either exported in your shell or
# via Scripts/.asc.env (auto-loaded if present).
#
# Required environment variables:
#   ASC_KEY_ID          the API key ID (e.g. "ABC123DEFG")
#   ASC_ISSUER_ID       the issuer UUID from ASC -> Users and Access -> Integrations
#   ASC_KEY_PATH        absolute path to the AuthKey_<ASC_KEY_ID>.p8
#                       (optional if it lives at ~/.appstoreconnect/private_keys/)
#
# Optional environment variables:
#   ASC_XCODE_PROJECT   xcode project (default "MyApp.xcodeproj")
#   ASC_XCODE_WORKSPACE xcode workspace (takes precedence over project if set)
#   ASC_XCODE_SCHEME    scheme name (default "MyApp")
#   ASC_CONFIGURATION   build config (default "Release")
#   ASC_EXPORT_OPTIONS  path to ExportOptions.plist (default "Templates/ExportOptions.plist")
#
# Usage:
#   ASC_KEY_ID=XXXX ASC_ISSUER_ID=YYYY ASC_KEY_PATH=/path/AuthKey_XXXX.p8 \
#     ASC_XCODE_PROJECT=MyApp.xcodeproj ASC_XCODE_SCHEME=MyApp \
#     Scripts/release-testflight.sh
#
#   # Build & export only, skip the upload (dry run of the archive):
#   Scripts/release-testflight.sh --no-upload
#
#   # Validate the archive against App Store Connect but don't deliver:
#   Scripts/release-testflight.sh --validate-only

set -euo pipefail

# ---- Configuration ---------------------------------------------------------
PROJECT="${ASC_XCODE_PROJECT:-MyApp.xcodeproj}"
WORKSPACE="${ASC_XCODE_WORKSPACE:-}"
SCHEME="${ASC_XCODE_SCHEME:-MyApp}"
CONFIGURATION="${ASC_CONFIGURATION:-Release}"

# Resolve repo root (parent of this script's Scripts/ directory) and cd into it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Look for ExportOptions.plist in a few sensible spots.
EXPORT_OPTIONS="${ASC_EXPORT_OPTIONS:-}"
if [ -z "${EXPORT_OPTIONS}" ]; then
	for candidate in \
		"Templates/ExportOptions.plist" \
		"Scripts/ExportOptions.plist" \
		"fastlane/ExportOptions.plist" \
		"ExportOptions.plist"; do
		if [ -f "${candidate}" ]; then
			EXPORT_OPTIONS="${candidate}"
			break
		fi
	done
fi

BUILD_DIR="${REPO_ROOT}/build"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}-${TIMESTAMP}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export-${TIMESTAMP}"

# ---- Flags -----------------------------------------------------------------
DO_UPLOAD=1
VALIDATE_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--no-upload)     DO_UPLOAD=0 ;;
		--validate-only) VALIDATE_ONLY=1 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*)
			echo "Unknown argument: $arg" >&2
			exit 2 ;;
	esac
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Load credentials from Scripts/.asc.env if present, so they don't have to be
# passed inline every run. Only variables that are unset are populated —
# anything already exported in the shell / CI env wins.
ENV_FILE="${SCRIPT_DIR}/.asc.env"
if [ -f "${ENV_FILE}" ]; then
	log "Loading credentials from ${ENV_FILE}"
	while IFS='=' read -r _key _val; do
		[[ "${_key}" =~ ^[[:space:]]*# ]] && continue
		[[ "${_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
		_val="${_val%\"}"; _val="${_val#\"}"
		_val="${_val%\'}"; _val="${_val#\'}"
		[ -z "${!_key:-}" ] && export "${_key}=${_val}"
	done < "${ENV_FILE}"
	unset _key _val
fi

# ---- Preflight -------------------------------------------------------------
command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode command line tools."
[ -n "${EXPORT_OPTIONS}" ] || fail "No ExportOptions.plist found. Set ASC_EXPORT_OPTIONS or drop one under Templates/."
[ -f "${EXPORT_OPTIONS}" ] || fail "Missing ${EXPORT_OPTIONS}"

if [ -n "${WORKSPACE}" ]; then
	[ -d "${WORKSPACE}" ] || fail "Workspace not found: ${WORKSPACE}"
else
	[ -d "${PROJECT}" ] || fail "Project not found: ${PROJECT}"
fi

AUTH_ARGS=()
resolve_auth() {
	[ -n "${ASC_KEY_ID:-}" ]    || fail "ASC_KEY_ID is not set."
	[ -n "${ASC_ISSUER_ID:-}" ] || fail "ASC_ISSUER_ID is not set."

	local key_path="${ASC_KEY_PATH:-}"
	if [ -z "${key_path}" ]; then
		key_path="${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
	fi
	[ -f "${key_path}" ] || fail "API key not found at: ${key_path}"
	RESOLVED_KEY_PATH="${key_path}"

	AUTH_ARGS=(
		-authenticationKeyPath "${key_path}"
		-authenticationKeyID "${ASC_KEY_ID}"
		-authenticationKeyIssuerID "${ASC_ISSUER_ID}"
	)
}

# Export needs ASC API auth for App Store Connect signing updates even when
# upload/validate are skipped. Always resolve when running xcodebuild export.
resolve_auth

mkdir -p "${BUILD_DIR}"

# Build target selectors (either -workspace or -project)
TARGET_ARGS=()
if [ -n "${WORKSPACE}" ]; then
	TARGET_ARGS=(-workspace "${WORKSPACE}" -scheme "${SCHEME}")
else
	TARGET_ARGS=(-project "${PROJECT}" -scheme "${SCHEME}")
fi

# ---- 1. Resolve packages ---------------------------------------------------
log "Resolving Swift package dependencies"
xcodebuild -resolvePackageDependencies "${TARGET_ARGS[@]}"

# ---- 2. Archive ------------------------------------------------------------
log "Archiving ${SCHEME} (${CONFIGURATION})"
xcodebuild archive \
	"${TARGET_ARGS[@]}" \
	-configuration "${CONFIGURATION}" \
	-archivePath "${ARCHIVE_PATH}" \
	-destination "generic/platform=iOS" \
	-allowProvisioningUpdates \
	CODE_SIGN_STYLE=Automatic

[ -d "${ARCHIVE_PATH}" ] || fail "Archive was not produced at ${ARCHIVE_PATH}"
log "Archive created: ${ARCHIVE_PATH}"

# ---- 3. Export .ipa --------------------------------------------------------
log "Exporting signed App Store .ipa"
xcodebuild -exportArchive \
	-archivePath "${ARCHIVE_PATH}" \
	-exportOptionsPlist "${EXPORT_OPTIONS}" \
	-exportPath "${EXPORT_PATH}" \
	-allowProvisioningUpdates \
	"${AUTH_ARGS[@]}"

IPA_PATH="$(/usr/bin/find "${EXPORT_PATH}" -maxdepth 1 -name '*.ipa' | head -n 1)"
[ -n "${IPA_PATH}" ] || fail "No .ipa found in ${EXPORT_PATH}"
log "Exported: ${IPA_PATH}"

if [ "${DO_UPLOAD}" -eq 0 ] && [ "${VALIDATE_ONLY}" -eq 0 ]; then
	log "Done (--no-upload). Upload manually with:"
	echo "  xcrun altool --upload-app -f \"${IPA_PATH}\" -t ios --apiKey \$ASC_KEY_ID --apiIssuer \$ASC_ISSUER_ID"
	exit 0
fi

# altool auto-discovers keys placed in ~/.appstoreconnect/private_keys/.
# Stage the resolved key there if it's somewhere else.
KEY_DIR="${HOME}/.appstoreconnect/private_keys"
EXPECTED_KEY="${KEY_DIR}/AuthKey_${ASC_KEY_ID}.p8"
if [ "${RESOLVED_KEY_PATH}" != "${EXPECTED_KEY}" ]; then
	mkdir -p "${KEY_DIR}"
	cp "${RESOLVED_KEY_PATH}" "${EXPECTED_KEY}"
fi

# ---- 4. Validate ----------------------------------------------------------
log "Validating .ipa against App Store Connect"
xcrun altool --validate-app \
	-f "${IPA_PATH}" \
	-t ios \
	--apiKey "${ASC_KEY_ID}" \
	--apiIssuer "${ASC_ISSUER_ID}"

if [ "${VALIDATE_ONLY}" -eq 1 ]; then
	log "Validation passed (--validate-only). Skipping upload."
	exit 0
fi

# ---- 5. Upload ------------------------------------------------------------
log "Uploading to App Store Connect / TestFlight"
xcrun altool --upload-app \
	-f "${IPA_PATH}" \
	-t ios \
	--apiKey "${ASC_KEY_ID}" \
	--apiIssuer "${ASC_ISSUER_ID}"

log "Upload complete. The build will appear in TestFlight after Apple finishes processing (usually 5-15 min)."
