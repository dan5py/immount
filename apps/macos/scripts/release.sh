#!/bin/zsh
# Builds a notarized Immount release and its Sparkle appcast.
#
#   scripts/release.sh             the next version, from the commits since the last release
#   scripts/release.sh 1.2.0       a specific version
#   scripts/release.sh --preview   only show the version, build number and release notes
#   --publish                      also commit, tag, push and create the GitHub release
#   --yes                          skip the confirmation (required without a terminal, e.g. CI)
#
# Versions come from Conventional Commits through git-cliff (see cliff.toml at the repository
# root): fix and perf bump the patch, feat the minor, a breaking change the major. The first
# release uses MARKETING_VERSION from Config/Version.xcconfig. The release notes are generated
# from the same commits and appear in the update window and on the GitHub release.
#
# The build number (CFBundleVersion, which Sparkle compares) is one more than the highest of
# Config/Version.xcconfig and every build already in the appcast, local or published.
#
# After a successful build the script writes Config/Version.xcconfig and CHANGELOG.md. With
# --publish it then commits them, tags the release, pushes the branch and the tag, and creates
# the GitHub release; otherwise it prints those commands, which work from any directory.
#
# Needs, once per Mac:
#   - git-cliff (brew install git-cliff).
#   - For --publish, the GitHub CLI signed in (brew install gh; gh auth login).
#   - Config/Local.xcconfig with your team, bundle ID, and IMMOUNT_UPDATE_FEED_URL and
#     IMMOUNT_UPDATE_PUBLIC_KEY. The feed must be a GitHub "releases/latest/download" URL.
#   - A notarytool keychain profile (default name "immount-notary"):
#       xcrun notarytool store-credentials immount-notary --apple-id <id> --team-id <team>
#   - The Sparkle EdDSA private key in the login Keychain (generate_keys). generate_appcast asks
#     for Keychain access the first time; choose Always Allow. On CI, set SPARKLE_KEY_FILE instead.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1 }

usage="usage: scripts/release.sh [<version>] [--preview] [--publish] [--yes]"
preview=false
publish=false
confirmed=false
version=
for arg in "$@"; do
    case $arg in
        --preview) preview=true ;;
        --publish) publish=true ;;
        --yes) confirmed=true ;;
        -*) fail $usage ;;
        *) [[ -z $version ]] || fail $usage; version=$arg ;;
    esac
done

profile=${NOTARY_PROFILE:-immount-notary}
root=${0:A:h:h}
repo_root=$(git -C $root rev-parse --show-toplevel)
command -v git-cliff >/dev/null || fail "git-cliff is not installed (brew install git-cliff)"
git -C $repo_root rev-parse -q --verify HEAD >/dev/null || fail "the repository has no commits yet"

# What gets built is the working tree; it must match the commit that will be tagged.
if ! $preview && [[ -n $(git -C $repo_root status --porcelain) ]]; then
    $publish && fail "uncommitted changes; --publish needs a clean working tree"
    [[ -n ${ALLOW_DIRTY:-} ]] || fail "uncommitted changes; commit or stash them first (or set ALLOW_DIRTY=1)"
fi

# Checked before the build, so publishing can't fail on them after a long notarization.
if ! $preview && $publish; then
    command -v gh >/dev/null || fail "the GitHub CLI is not installed (brew install gh)"
    gh auth status --hostname github.com >/dev/null 2>&1 || fail "the GitHub CLI is not signed in (gh auth login)"
    git -C $repo_root symbolic-ref -q HEAD >/dev/null || fail "--publish needs a branch to push, not a detached HEAD"
fi

setting() {
    print -r -- $settings | awk -F' = ' -v key=" $1 = " 'index($0, key) { print $2; exit }'
}
settings=$(xcodebuild -project $root/immount.xcodeproj -scheme immount -configuration Release -showBuildSettings 2>/dev/null)
team=$(setting DEVELOPMENT_TEAM)
feed=$(setting IMMOUNT_UPDATE_FEED_URL)
public_key=$(setting IMMOUNT_UPDATE_PUBLIC_KEY)
[[ -n $team ]] || fail "set DEVELOPMENT_TEAM in Config/Local.xcconfig"
[[ -n $feed && -n $public_key ]] || fail "set IMMOUNT_UPDATE_FEED_URL and IMMOUNT_UPDATE_PUBLIC_KEY in Config/Local.xcconfig"
# https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
if [[ $feed =~ '^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$' ]]; then
    repo=$match[1]
else
    fail "IMMOUNT_UPDATE_FEED_URL must be https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml"
fi

cliff() { git -C $repo_root cliff --config $repo_root/cliff.toml "$@" }

# The version: given, the first one, or bumped from the commits since the last release tag.
last_tag=$(git -C $repo_root tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
if [[ -z $version ]]; then
    if [[ -z $last_tag ]]; then
        version=$(setting MARKETING_VERSION)
    else
        version=$(cliff --bumped-version 2>/dev/null)
        version=${version#v}
        [[ v$version != $last_tag ]] || fail "no user-facing changes since $last_tag (only feat, fix and perf count)"
    fi
fi
version=${version#v}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "the version must look like 1.2.3, not $version"
git -C $repo_root rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "v$version is already tagged"

out=$root/build/release
archive=$out/Immount.xcarchive
export_dir=$out/export
packages=$out/SourcePackages
updates=$out/updates # Kept between releases: generate_appcast keeps older entries in the appcast.
app=$export_dir/Immount.app
zip=$updates/Immount-$version.zip
notes=$updates/Immount-$version.md # generate_appcast embeds the notes that share the archive's name.
version_file=$root/Config/Version.xcconfig

# Everything already released: this Mac's appcast and the published one (other Macs may release).
appcasts=$(cat $updates/appcast.xml 2>/dev/null || true; curl -fsSL --max-time 15 $feed 2>/dev/null || true)
if print -r -- $appcasts | grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>"; then
    fail "$version is already in the appcast; pick a new version"
fi
released=$(print -r -- $appcasts | sed -n 's|.*<sparkle:version>\([0-9]*\)</sparkle:version>.*|\1|p' | sort -n | tail -1)
current=$(setting CURRENT_PROJECT_VERSION)
build=$(( (${current:-0} > ${released:-0} ? ${current:-0} : ${released:-0}) + 1 ))

# The notes: this version's changelog section without its "## version - date" heading.
release_notes=$(cliff --unreleased --tag v$version --strip all 2>/dev/null | sed '1{/^## /d;}' | sed '/./,$!d')

if $preview; then
    echo "Immount $version ($build)${last_tag:+, after $last_tag}"
    echo
    print -r -- ${release_notes:-(no user-facing changes)}
    exit 0
fi

echo "Release Immount $version ($build)${last_tag:+, after $last_tag}:"
echo
print -r -- ${release_notes:-(no user-facing changes)}
echo
if ! $confirmed; then
    [[ -t 0 ]] || fail "no terminal to confirm in; pass --yes to release without asking"
    if $publish; then
        read -q "?Build, notarize, package and publish it on GitHub? [y/N] " || { echo; exit 1 }
    else
        read -q "?Build, notarize and package it? [y/N] " || { echo; exit 1 }
    fi
    echo
fi

rm -rf $archive $export_dir
mkdir -p $updates
rm -f $notes
[[ -n $release_notes ]] && print -r -- $release_notes > $notes

echo "==> Archiving $version ($build)"
xcodebuild archive \
    -project $root/immount.xcodeproj \
    -scheme immount \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath $archive \
    -clonedSourcePackagesDirPath $packages \
    MARKETING_VERSION=$version \
    CURRENT_PROJECT_VERSION=$build \
    -quiet

echo "==> Exporting with Developer ID"
export_options=$(mktemp -t immount-export).plist
cat > $export_options <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath $archive \
    -exportOptionsPlist $export_options \
    -exportPath $export_dir \
    -allowProvisioningUpdates \
    -quiet
rm -f $export_options

echo "==> Notarizing"
submission=$out/Immount-notarize.zip
ditto -c -k --sequesterRsrc --keepParent $app $submission
xcrun notarytool submit $submission --keychain-profile $profile --wait
xcrun stapler staple $app
rm -f $submission

echo "==> Packaging"
rm -f $zip
ditto -c -k --sequesterRsrc --keepParent $app $zip

echo "==> Generating the appcast"
generate_appcast=$packages/artifacts/sparkle/Sparkle/bin/generate_appcast
key_args=()
[[ -n ${SPARKLE_KEY_FILE:-} ]] && key_args=(--ed-key-file $SPARKLE_KEY_FILE)
$generate_appcast $key_args \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --link "https://github.com/$repo" \
    --maximum-deltas 0 \
    --embed-release-notes \
    $updates

# Only now, so a failed run never leaves a half-bumped version or changelog behind.
sed -i '' -E \
    -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" \
    -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build/" \
    $version_file
cliff --tag v$version --output $repo_root/CHANGELOG.md 2>/dev/null

version_path=${version_file#$repo_root/}
appcast=$updates/appcast.xml
title="Immount $version"
message="chore(release): v$version"
notes_arg=--generate-notes
[[ -f $notes ]] && notes_arg="--notes-file ${(q-)notes}"
# Every command names the repository, so they run from any directory. The push is atomic, so
# the tag never reaches GitHub without its commit, and the release only uses a pushed tag.
git_cmd="git -C ${(q-)repo_root}"
steps=(
    "$git_cmd add ${(q-)version_path} CHANGELOG.md"
    "$git_cmd commit -m ${(q-)message} -- ${(q-)version_path} CHANGELOG.md"
    "$git_cmd tag v$version"
    "$git_cmd push --atomic origin HEAD v$version"
    "gh release create v$version ${(q-)zip} ${(q-)appcast} --repo $repo --title ${(q-)title} --verify-tag $notes_arg"
)

cat <<EOF

Done: Immount $version ($build)
      $zip
      $appcast

Updated $version_path and CHANGELOG.md.
EOF

if ! $publish; then
    echo "To publish (the appcast must be attached to every release, since the app reads the latest one):"
    echo
    print -rl -- "  "${^steps}
    exit 0
fi

for (( i = 1; i <= $#steps; i++ )); do
    echo "==> ${steps[i]}"
    if ! eval ${steps[i]}; then
        echo "error: publishing stopped; once fixed, run the rest:" >&2
        print -rl -- "  "${^steps[i,-1]} >&2
        exit 1
    fi
done
echo
echo "Published: https://github.com/$repo/releases/tag/v$version"
