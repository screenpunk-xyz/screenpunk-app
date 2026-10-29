#!/bin/bash
set -euo pipefail
: "${CI_SCRATCH_ROOT:?Run tools/ci/storage.mjs init first}"
: "${DEVELOPER_DIR:?Select the reviewed Xcode explicitly}"
test -f "$CI_SCRATCH_ROOT/ownership.json"
mkdir -p "$CI_SCRATCH_ROOT/build" "$CI_SCRATCH_ROOT/evidence"
xcodebuild -version | tee "$CI_SCRATCH_ROOT/evidence/xcode.txt"
test "$(xcodebuild -version)" = $'Xcode 26.6\nBuild version 17F113' || { echo 'Reviewed Xcode unavailable; update the pin after verification.'; exit 1; }
# These suites use real macOS JXA against isolated synthetic fixture homes.
# Never enable optional host launchctl probes or invoke the actual setup installer.
export SCREENPUNK_SETUP_TEST_ROOT="$CI_SCRATCH_ROOT/evidence/setup-fixtures"
export SCREENPUNK_SETUP_TEST_OWNER="${GITHUB_REPOSITORY:-local}/${GITHUB_RUN_ID:-manual}/mac-setup-fixtures"
unset SCREENPUNK_SETUP_SERVICE_JOB_READONLY SCREENPUNK_SETUP_SERVICE_JOB_CAPTURE
node --test tools/local-agent-setup/tests.mjs 2>&1 | tee "$CI_SCRATCH_ROOT/evidence/local-setup-tests.log"
node --test tools/local-agent-setup/native-service-job-test.mjs 2>&1 | tee "$CI_SCRATCH_ROOT/evidence/local-setup-job-tests.log"
node --test tools/local-agent-setup/native-service-upgrade-test.mjs 2>&1 | tee "$CI_SCRATCH_ROOT/evidence/local-setup-upgrade-tests.log"
for entry in 'core:packages/ScreenpunkCore' 'device:apps/device' 'apple:packages/ScreenpunkApple' 'transport:packages/ScreenpunkLocalTransport' 'authoring:packages/ScreenpunkLocalAuthoring'; do
  name=${entry%%:*}
  package=${entry#*:}
  swift test --package-path "$package" --scratch-path "$CI_SCRATCH_ROOT/build/$name" --force-resolved-versions 2>&1 | tee "$CI_SCRATCH_ROOT/evidence/$name-tests.log"
done
for sdk in iphoneos iphonesimulator; do
  xcodebuild -project apps/device/ScreenpunkOne.xcodeproj -scheme ScreenpunkOne -configuration Debug -sdk "$sdk" -destination "generic/platform=$([ "$sdk" = iphoneos ] && echo iOS || echo 'iOS Simulator')" -derivedDataPath "$CI_SCRATCH_ROOT/build/derived-data" -clonedSourcePackagesDirPath "$CI_SCRATCH_ROOT/build/xcode-packages" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$CI_SCRATCH_ROOT/evidence/$sdk-build.log"
done
