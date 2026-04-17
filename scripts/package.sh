#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
PROJECT_PATH="$ROOT_DIR/macos/swift-ui/swift-ui.xcodeproj"
SCHEME="${SCHEME:-swift-ui}"
CONFIGURATION="${CONFIGURATION:-Release}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"

APP_ARCH="${APP_ARCH:-}"
if [ -z "$APP_ARCH" ]; then
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    arm64|aarch64)
      APP_ARCH="arm64"
      ;;
    x86_64|amd64)
      APP_ARCH="x64"
      ;;
    *)
      echo "Unsupported architecture: $ARCH_RAW"
      exit 1
      ;;
  esac
else
  case "$APP_ARCH" in
    arm64|aarch64)
      APP_ARCH="arm64"
      ;;
    x64|x86_64|amd64)
      APP_ARCH="x64"
      ;;
    *)
      echo "Unsupported APP_ARCH: $APP_ARCH"
      echo "Use APP_ARCH=arm64 or APP_ARCH=x64"
      exit 1
      ;;
  esac
fi

echo "Preparing resources for macOS ($APP_ARCH)..."
PREPARE_EXTRA_ARGS=""
if [ "${REUSE_RESOURCES:-0}" = "1" ]; then
  PREPARE_EXTRA_ARGS="--reuse"
fi
pnpm prepare "--$APP_ARCH" $PREPARE_EXTRA_ARGS

VERSION="$(node -p "JSON.parse(require('fs').readFileSync('package.json', 'utf8')).version")"
BASE_VERSION="${VERSION%%-*}"

if [[ "$VERSION" == *-* ]]; then
  # dev 构建使用纯数字 build，避免 CFBundleVersion 带后缀导致比较问题
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
else
  BUILD_NUMBER="$BASE_VERSION"
fi

echo "Building Swift app (version: $VERSION, marketing: $BASE_VERSION, build: $BUILD_NUMBER)..."
echo "Using macOS deployment target: $MIN_MACOS_VERSION"
rm -rf "$DERIVED_DATA_DIR"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  MARKETING_VERSION="$BASE_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_VERSION" \
  APP_ARCH="$APP_ARCH" \
  build

APP_PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
shopt -s nullglob
app_candidates=("$APP_PRODUCTS_DIR"/*.app)
shopt -u nullglob

if [ "${#app_candidates[@]}" -eq 0 ]; then
  echo "Failed to find built .app in $APP_PRODUCTS_DIR"
  exit 1
fi
APP_PATH="${app_candidates[0]}"

mkdir -p "$DIST_DIR"

APP_BUNDLE_PATH="$DIST_DIR/airtiz.app"

echo "Syncing app bundle to dist..."
rm -rf "$APP_BUNDLE_PATH"
ditto "$APP_PATH" "$APP_BUNDLE_PATH"

echo "Done. App bundle ready at: $APP_BUNDLE_PATH"

echo "  下一步：运行 sign.sh 签名"
echo "    bash scripts/sign.sh"
echo ""
