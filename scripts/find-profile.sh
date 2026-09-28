#!/bin/bash
# Print the path of an installed Mac development provisioning profile that
# covers Better Teams' communication-notification entitlement for the given
# signing identity (name or SHA-1). Prints nothing when none matches; the
# caller then signs without entitlements (a restricted entitlement with no
# matching profile makes AMFI kill the app at launch).
# Criteria: app id U2BLPMMTCS.dev.ostmac.OstMac, communication entitlement,
# not expired, this Mac's provisioning UDID listed, identity cert included.
set -uo pipefail
IDENT="${1:-}"
[[ -n "$IDENT" ]] || exit 0
APP_ID="U2BLPMMTCS.dev.ostmac.OstMac"
SHA="$(security find-identity -v -p codesigning | grep -F -- "$IDENT" | awk 'NR==1{print $2}')"
[[ -n "$SHA" ]] || exit 0
UDID="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/{print $2}')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMPP="$(mktemp -t ostmac-profile)"
trap 'rm -f "$TMPP"' EXIT
for P in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
         "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
    [[ -f "$P" ]] || continue
    security cms -D -i "$P" > "$TMPP" 2>/dev/null || continue
    [[ "$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$TMPP" 2>/dev/null)" == "$APP_ID" ]] || continue
    [[ "$(plutil -extract Entitlements.com\\.apple\\.developer\\.usernotifications\\.communication raw -o - "$TMPP" 2>/dev/null)" == "true" ]] || continue
    EXP="$(plutil -extract ExpirationDate raw -o - "$TMPP" 2>/dev/null)"
    [[ -n "$EXP" && "$EXP" > "$NOW" ]] || continue
    [[ -n "$UDID" ]] && ! grep -qF "$UDID" "$TMPP" && continue
    N="$(plutil -extract DeveloperCertificates raw -o - "$TMPP" 2>/dev/null)"
    for ((i = 0; i < ${N:-0}; i++)); do
        C="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$TMPP" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')"
        if [[ "$C" == "$SHA" ]]; then
            echo "$P"
            exit 0
        fi
    done
done
exit 0
