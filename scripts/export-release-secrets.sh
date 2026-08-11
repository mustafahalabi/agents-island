#!/bin/bash
# Collect the values .github/workflows/release.yml needs as repository secrets,
# and print the `gh secret set` command for each one.
#
#   ./scripts/export-release-secrets.sh
#
# Nothing is uploaded and nothing is written outside a temp directory that is
# shredded on exit — the script gathers, you decide. Run it on the Mac whose
# Keychain currently cuts releases, since that is where the keys are.
#
# The one thing it cannot do for you is the .p12: `security export` dumps every
# identity in the Keychain into one file, and shipping unrelated private keys to
# GitHub is worse than a manual step. Instructions for that are printed below.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-mustafahalabi/agents-island}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---- Team ID + signing identity --------------------------------------------
# The Team ID is the parenthesised suffix of the identity name, so it never has
# to be looked up on the developer portal.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true
if [ -z "$IDENTITY" ]; then
    echo "No 'Developer ID Application' identity in this Keychain." >&2
    echo "Run this on the Mac that cuts releases today." >&2
    exit 1
fi
TEAM_ID=$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')

say "Found: $IDENTITY"

say "1. APPLE_TEAM_ID"
echo "  gh secret set APPLE_TEAM_ID --repo $REPO --body '$TEAM_ID'"

# ---- Sparkle private key ----------------------------------------------------
say "2. SPARKLE_PRIVATE_KEY"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
if [ -x "$SPARKLE_BIN/generate_keys" ]; then
    # -x writes the private key to a file; the Keychain will ask for permission.
    if "$SPARKLE_BIN/generate_keys" -x "$TMP/sparkle_key" >/dev/null 2>&1 \
       && [ -s "$TMP/sparkle_key" ]; then
        echo "  gh secret set SPARKLE_PRIVATE_KEY --repo $REPO < $TMP/sparkle_key"
        echo "  ^ that file is deleted when this script exits — run the command now,"
        echo "    in another shell, or copy the key into a password manager first."
        echo
        echo "  key:"
        sed 's/^/    /' "$TMP/sparkle_key"
    else
        echo "  generate_keys could not export the key (did you deny the Keychain prompt?)."
        echo "  Retry:  $SPARKLE_BIN/generate_keys -x sparkle_key"
    fi
else
    echo "  $SPARKLE_BIN/generate_keys not built yet — run 'swift build' first."
fi

# ---- Certificate ------------------------------------------------------------
say "3. MACOS_CERT_P12 and MACOS_CERT_PASSWORD  (manual, on purpose)"
cat <<EOF
  Keychain Access → login → My Certificates → select exactly:
      $IDENTITY
  Right-click → Export… → save as cert.p12 → set a password you'll reuse below.
  Then:
      base64 -i cert.p12 | gh secret set MACOS_CERT_P12 --repo $REPO
      gh secret set MACOS_CERT_PASSWORD --repo $REPO   # paste that password
      rm cert.p12
  Export the certificate row (which carries its private key), not the bare key.
EOF

# ---- Things only you know ---------------------------------------------------
say "4. APPLE_ID and APPLE_APP_PASSWORD"
cat <<EOF
  gh secret set APPLE_ID --repo $REPO            # the Apple ID used to notarize
  gh secret set APPLE_APP_PASSWORD --repo $REPO  # app-specific password from
                                                 # account.apple.com → Sign-In
                                                 # and Security. Not your normal
                                                 # Apple ID password.
EOF

say "5. TAP_DEPLOY_KEY"
cat <<EOF
  GITHUB_TOKEN cannot push to another repository, so the cask bump needs its own
  credential — otherwise the release ships and the cask stays behind. A deploy
  key grants write to homebrew-tap and nothing else, unlike a PAT, and needs no
  Keychain access to mint:
      ssh-keygen -t ed25519 -N '' -C 'agents-island release workflow' -f tap_key
      gh api -X POST repos/mustafahalabi/homebrew-tap/keys \\
          -f title='agents-island release workflow' \\
          -f key="\$(cat tap_key.pub)" -F read_only=false
      gh secret set TAP_DEPLOY_KEY --repo $REPO < tap_key
      rm tap_key tap_key.pub
  Already registered ones: gh api repos/mustafahalabi/homebrew-tap/keys
EOF

say "Check what is set:  gh secret list --repo $REPO"
