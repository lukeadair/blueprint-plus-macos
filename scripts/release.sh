#!/bin/zsh
# Builds Blueprint+-<version>.dmg, publishes it as GitHub release v<version>, and bumps the Homebrew cask.
# Bump MARKETING_VERSION first. DRY_RUN=1 stops after the DMG. TAP_DIR: checkout of lukeadair/homebrew-tap.
set -euo pipefail
cd "${0:A:h}/.."
TAP_DIR=${TAP_DIR:-../homebrew-tap}
PROJ=(-project BlueprintPlus.xcodeproj -scheme BlueprintPlus)

VER=$(xcodebuild $PROJ -configuration Release -showBuildSettings 2>/dev/null | awk '$1=="MARKETING_VERSION"{print $3}')
[[ -n $VER ]] || { echo "no MARKETING_VERSION"; exit 1; }
if [[ -z ${DRY_RUN:-} ]]; then
  [[ -z $(git status --porcelain) ]] || { echo "commit your changes first"; exit 1; }
  ! git rev-parse -q --verify "refs/tags/v$VER" >/dev/null || { echo "v$VER already exists: bump MARKETING_VERSION"; exit 1; }
fi

xcodebuild $PROJ -destination 'platform=macOS' -quiet test
rm -rf build/release
# Universal so the one DMG runs on Intel Macs too (macOS 26 still supports them).
xcodebuild $PROJ -configuration Release -derivedDataPath build/release -quiet ONLY_ACTIVE_ARCH=NO build
APP=build/release/Build/Products/Release/Blueprint+.app

STAGE=build/release/dmg DMG=build/Blueprint+-$VER.dmg
mkdir -p $STAGE && cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
rm -f $DMG && hdiutil create -quiet -volname "Blueprint+" -srcfolder $STAGE -format UDZO $DMG
SHA=$(shasum -a 256 $DMG | cut -d' ' -f1)
echo "$DMG  $SHA"
[[ -z ${DRY_RUN:-} ]] || exit 0

git tag v$VER && git push origin v$VER
gh release create v$VER $DMG --title "Blueprint+ $VER" --generate-notes

CASK=$TAP_DIR/Casks/blueprint-plus.rb
git -C $TAP_DIR pull -q
sed -i '' -e "s/^  version \".*\"/  version \"$VER\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" $CASK
git -C $TAP_DIR commit -qam "blueprint-plus $VER" && git -C $TAP_DIR push -q
echo "Released v$VER"
