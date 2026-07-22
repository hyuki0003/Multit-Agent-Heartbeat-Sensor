#!/bin/bash
set -euo pipefail

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

signing_identity="${HERMES_MONITOR_CODE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    fail "HERMES_MONITOR_CODE_SIGN_IDENTITY is required and must name a usable external code-signing identity"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

normalize_absolute_path() {
    local path="$1"
    local component
    local index
    local -a components=()
    local -a normalized=()
    local IFS="/"

    read -r -a components <<<"$path"
    for component in "${components[@]}"; do
        case "$component" in
            ""|.)
                ;;
            ..)
                if (( ${#normalized[@]} > 0 )); then
                    index=$((${#normalized[@]} - 1))
                    unset "normalized[$index]"
                fi
                ;;
            *)
                normalized[${#normalized[@]}]="$component"
                ;;
        esac
    done

    if (( ${#normalized[@]} == 0 )); then
        printf '/\n'
    else
        printf '/%s' "${normalized[@]}"
        printf '\n'
    fi
}

resolve_build_root() {
    local candidate="$1"
    local suffix=""
    local leaf
    local parent
    local resolved

    if [[ "$candidate" != /* ]]; then
        candidate="$repo_root/$candidate"
    fi
    while [[ "$candidate" != "/" && "$candidate" == */ ]]; do
        candidate="${candidate%/}"
    done
    while [[ ! -e "$candidate" ]]; do
        [[ ! -L "$candidate" ]] \
            || fail "production build root contains an unresolved symbolic link"
        leaf="${candidate##*/}"
        parent="${candidate%/*}"
        [[ -n "$parent" ]] || parent="/"
        suffix="/$leaf$suffix"
        candidate="$parent"
    done
    [[ -d "$candidate" ]] || fail "production build root must resolve to a directory"
    resolved="$(cd -P "$candidate" && pwd -P)" \
        || fail "production build root could not be resolved"
    normalize_absolute_path "$resolved$suffix"
}

build_root="$(resolve_build_root "${HERMES_MONITOR_BUILD_ROOT:-$repo_root/.build/production}")"
case "$build_root" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*)
        fail "production build root must not be under /tmp"
        ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "the signed production app must be built on macOS"
fi

for tool in xcodegen xcodebuild security codesign lipo; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

generated_root="$build_root/GeneratedProject"
derived_data="$build_root/DerivedData"
install_root="$build_root/InstallRoot"
app_path="$install_root/Applications/Hermes Monitor.app"
executable_path="$app_path/Contents/MacOS/Hermes Monitor"
expected_architecture="arm64"

identity_listing="$(security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db")" \
    || fail "could not query usable code-signing identities"
if ! /usr/bin/awk -v expected="$signing_identity" '
    /^[[:space:]]*[0-9]+\)/ {
        quote = index($0, "\"")
        if (quote > 0 && substr($0, quote) == "\"" expected "\"") {
            found = 1
        }
    }
    END { exit(found ? 0 : 1) }
' <<<"$identity_listing"; then
    fail "the supplied identity is not usable for code signing"
fi

mkdir -p "$generated_root" "$derived_data" "$install_root"
ln -sfn "$repo_root/Sources" "$generated_root/Sources"
ln -sfn "$repo_root/Info.plist" "$generated_root/Info.plist"
ln -sfn "$repo_root/HermesMonitor-Bridging-Header.h" \
    "$generated_root/HermesMonitor-Bridging-Header.h"
cp "$repo_root/project.yml" "$generated_root/project.yml"

(
    cd "$generated_root"
    xcodegen generate --spec project.yml
)

xcodebuild \
    -project "$generated_root/HermesMonitor.xcodeproj" \
    -scheme HermesMonitor \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    install \
    DSTROOT="$install_root" \
    HERMES_MONITOR_CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    ARCHS="$expected_architecture" \
    ONLY_ACTIVE_ARCH=NO

[[ -d "$app_path" ]] || fail "xcodebuild did not produce $app_path"
[[ -x "$executable_path" ]] || fail "application executable is missing: $executable_path"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
bundle_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app_path/Contents/Info.plist")"
[[ "$bundle_identifier" == "com.hermes.monitor.app" ]] \
    || fail "unexpected bundle identifier: $bundle_identifier"
[[ "$bundle_executable" == "Hermes Monitor" ]] \
    || fail "unexpected bundle executable: $bundle_executable"
[[ "$bundle_package_type" == "APPL" ]] \
    || fail "unexpected bundle package type: $bundle_package_type"

actual_architecture="$(lipo -archs "$executable_path")"
[[ "$actual_architecture" == "$expected_architecture" ]] \
    || fail "unexpected executable architecture: $actual_architecture"

codesign --verify --deep --strict --verbose=2 "$app_path"
designated_requirement="$(codesign -d -r- "$app_path" 2>&1)" \
    || fail "could not read the signed application's designated requirement"
[[ "$designated_requirement" == *'identifier "com.hermes.monitor.app"'* ]] \
    || fail "designated requirement does not bind the stable bundle identifier"

printf 'Verified signed production app: %s\n' "$app_path"
printf 'Architecture: %s\n' "$actual_architecture"
printf 'Bundle identifier: %s\n' "$bundle_identifier"
