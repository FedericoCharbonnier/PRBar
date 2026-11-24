#!/bin/bash
# Publica una versión de PRBar (spec D.1):
#   1. chequea gh, la rama main limpia y al día con origin, y que el tag no exista;
#   2. arma las notas con los commits desde el tag anterior y las abre en $EDITOR (vacías = cancelar);
#   3. sube la versión (CFBundleShortVersionString, CFBundleVersion + 1 y PRBarCore.version);
#   4. arma PRBar.app igual que el actualizador (`Scripts/bundle.sh --output`: release y `--force-resolved-versions`),
#      prueba lo que armó (la firma, la versión del bundle y `prbar --version`), corre `swift run PRBarTests` y chequea
#      que el build no haya cambiado nada más (p. ej. `Package.resolved`). Si algo falla, revierte el cambio de versión;
#   5. commitea "Release vX.Y.Z", crea el tag anotado vX.Y.Z, pushea los dos y crea el GitHub Release.
# Uso: Scripts/release.sh [--dry-run] <X.Y.Z>
#   --dry-run  corre los chequeos (los que fallan solo avisan), el build y los tests, muestra las notas y lista los
#              pasos que cambiarían algo (archivos, commit, tag, push, release) sin hacerlos. No hace `git fetch`:
#              compara con origin con `git ls-remote` (las notas salen de los tags locales).
set -euo pipefail

usage() {
    echo "Usage: Scripts/release.sh [--dry-run] <X.Y.Z>" >&2
    exit 2
}

DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *)
            [[ -z "$VERSION" ]] || usage
            VERSION="$arg"
            ;;
    esac
done
[[ -n "$VERSION" ]] || usage
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "release: the version must look like X.Y.Z (got \"$VERSION\")." >&2
    exit 2
fi

cd "$(dirname "$0")/.."
PLIST=Resources/Info.plist
CORE=Sources/PRBarCore/PRBarCore.swift
BRANCH=main
TAG="v$VERSION"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }

# 0 si $1 > $2 (los dos X.Y.Z).
version_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
        if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
    done
    return 1
}

CURRENT="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
if ! version_gt "$VERSION" "$CURRENT"; then
    echo "release: $VERSION must be greater than the current version ($CURRENT)." >&2
    exit 2
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "release: CFBundleVersion ($BUILD) isn't a number." >&2
    exit 1
fi
NEXT_BUILD=$((BUILD + 1))

step() { printf '\n==> %s\n' "$*"; }

# Lo que cambia algo (archivos, git, GitHub): en --dry-run solo se muestra.
run() {
    if (( DRY_RUN )); then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Un chequeo que no se cumple: corta la release; en --dry-run avisa y sigue, para ver el resto del plan.
fail() {
    if (( DRY_RUN )); then
        echo "[dry-run] a real release would stop here: $*" >&2
    else
        echo "release: $*" >&2
        exit 1
    fi
}

NOTES="$(mktemp -t prbar-release-notes)"
BUMPED=0
BUILD_OUT=""
cleanup() {
    rm -f "$NOTES"
    if [[ -n "$BUILD_OUT" ]]; then rm -rf "$BUILD_OUT"; fi
    if (( BUMPED )); then
        git checkout -- "$PLIST" "$CORE"
        echo "release: the version change was reverted; nothing was committed." >&2
    fi
}
trap cleanup EXIT

MODE=""
if (( DRY_RUN )); then MODE=" — dry run"; fi
step "PRBar $CURRENT → $VERSION (build $NEXT_BUILD)$MODE"

step "Checking tools"
for tool in git swift gh; do
    command -v "$tool" >/dev/null || fail "\`$tool\` isn't installed."
done
gh auth status --hostname github.com >/dev/null 2>&1 || fail "gh isn't signed in (run \`gh auth login\`)."
REPO="${PRBAR_RELEASE_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || fail "couldn't tell the GitHub repo (set PRBAR_RELEASE_REPO=owner/name)."
echo "Repo: ${REPO:-unknown}"

step "Checking the working tree"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || fail "you're not on $BRANCH."
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes."
if (( DRY_RUN )); then
    # Sin fetch: ni origin/main ni los tags locales ni FETCH_HEAD cambian.
    ORIGIN_HEAD="$(git ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | cut -f1 || true)"
    echo "[dry-run] compared with origin using git ls-remote (nothing was fetched)."
    [[ -n "$ORIGIN_HEAD" ]] || fail "couldn't read $BRANCH from origin."
else
    git fetch --quiet --tags origin "$BRANCH" || fail "couldn't fetch origin."
    ORIGIN_HEAD="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"
fi
[[ "$(git rev-parse HEAD)" == "$ORIGIN_HEAD" ]] || fail "$BRANCH isn't the same as origin/$BRANCH (pull or push first)."
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then fail "the tag $TAG already exists."; fi
if [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]]; then fail "the tag $TAG already exists on origin."; fi

step "Release notes"
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
{
    echo "#~ Release notes for PRBar $VERSION (commits since ${PREVIOUS:-the beginning})."
    echo "#~ Lines starting with #~ are removed (Markdown headings like ## stay). Leave the file empty to cancel the release."
    git log --no-merges --reverse --pretty='- %s' ${PREVIOUS:+"$PREVIOUS..HEAD"}
} > "$NOTES"
if (( DRY_RUN )); then
    echo "[dry-run] these notes would open in your editor:"
    grep -v '^#~' "$NOTES" || true
else
    ${VISUAL:-${EDITOR:-vi}} "$NOTES"
fi
sed -i '' '/^#~/d' "$NOTES"
if ! grep -q '[^[:space:]]' "$NOTES"; then
    if (( DRY_RUN )); then
        echo "[dry-run] the notes are empty: a real release would stop here." >&2
    else
        echo "release: the notes are empty, nothing was released." >&2
        exit 1
    fi
fi

step "Setting the version to $VERSION (build $NEXT_BUILD)"
# Antes de tocar nada: si falla a mitad de camino, la salida revierte lo que se haya cambiado.
if (( ! DRY_RUN )); then BUMPED=1; fi
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"
run sed -i '' -E "s/(static let version = \")[^\"]*(\")/\\1$VERSION\\2/" "$CORE"
if (( ! DRY_RUN )); then
    grep -q "static let version = \"$VERSION\"" "$CORE" || fail "couldn't update $CORE."
fi
BUILT_VERSION="$VERSION"
if (( DRY_RUN )); then BUILT_VERSION="$CURRENT"; fi

step "Building PRBar.app the way the in-app updater does"
# Lo mismo que corre `UpdateInstaller` en cada Mac: release y exactamente lo de Package.resolved. Si esto no compila,
# ninguna actualización compilaría.
BUILD_OUT="$(mktemp -d -t prbar-release-build)"
# /bin/bash, como `UpdateInstaller`: un `bash` x86_64 del PATH (Homebrew Intel) corre `swift` bajo Rosetta, compila
# en .build/x86_64-… y el chequeo de abajo (`--show-bin-path`, arm64) leería otra compilación.
/bin/bash Scripts/bundle.sh --output "$BUILD_OUT"
APP="$BUILD_OUT/PRBar.app"

step "Checking the built app"
codesign --verify --strict "$APP/Contents/Helpers/prbar" || fail "the built prbar isn't signed correctly."
codesign --verify --deep --strict "$APP" || fail "the built PRBar.app isn't signed correctly."
[[ -x "$APP/Contents/MacOS/PRBar" ]] || fail "the built PRBar.app has no executable."
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$BUILT_VERSION" ]] || fail "the built PRBar.app says $APP_VERSION, expected $BUILT_VERSION."
CLI_VERSION="$("$APP/Contents/Helpers/prbar" --version 2>&1 || true)"
[[ "$CLI_VERSION" == "$BUILT_VERSION" ]] || fail "the built prbar --version says \"$CLI_VERSION\", expected $BUILT_VERSION."
"$APP/Contents/Helpers/prbar" --help >/dev/null || fail "the built prbar --help failed."
# Fuera del bundle, `--version` es la de PRBarCore: la que quedó compilada.
RELEASE_BIN="$(swift build -c release --force-resolved-versions --show-bin-path)"
CORE_VERSION="$("$RELEASE_BIN/PRBarCLI" --version 2>&1 || true)"
[[ "$CORE_VERSION" == "$BUILT_VERSION" ]] || fail "the release build of PRBarCore says \"$CORE_VERSION\", expected $BUILT_VERSION."
echo "PRBar.app $APP_VERSION and prbar $CLI_VERSION look right."

step "Testing"
swift run PRBarTests

step "Checking that the build changed nothing else"
# P. ej. un Package.resolved que se resolvió de nuevo: no se commitearía y el tag no compilaría igual en otra Mac.
OTHER_CHANGES="$(git status --porcelain --untracked-files=no | grep -v -e " $PLIST\$" -e " $CORE\$" || true)"
[[ -z "$OTHER_CHANGES" ]] || fail "building changed files that wouldn't be released: $OTHER_CHANGES"

step "Committing and tagging"
run git commit --quiet -m "Release $TAG" -- "$PLIST" "$CORE"
BUMPED=0
if ! run git tag -a "$TAG" -m "PRBar $VERSION"; then
    echo "release: tagging failed. The commit \"Release $TAG\" is only local: fix the problem and run" >&2
    echo "  git tag -a $TAG -m \"PRBar $VERSION\" && git push --atomic origin $BRANCH $TAG" >&2
    echo "  gh release create $TAG --repo $REPO --title \"PRBar $VERSION\" --verify-tag" >&2
    echo "or drop it with: git reset --hard HEAD~1" >&2
    exit 1
fi

step "Pushing $BRANCH and $TAG"
if ! run git push --atomic origin "$BRANCH" "$TAG"; then
    echo "release: the push failed. The commit and the tag are only local: fix the problem and run" >&2
    echo "  git push --atomic origin $BRANCH $TAG && gh release create $TAG --title \"PRBar $VERSION\" --verify-tag" >&2
    exit 1
fi

step "Creating the GitHub release"
if ! run gh release create "$TAG" --repo "$REPO" --title "PRBar $VERSION" --notes-file "$NOTES" --verify-tag; then
    # El commit y el tag ya están en origin: falta solo el release. Las notas se guardan para reintentar.
    KEPT_NOTES="${TMPDIR:-/tmp}"
    KEPT_NOTES="${KEPT_NOTES%/}/prbar-release-notes-$TAG.md"
    cp "$NOTES" "$KEPT_NOTES"
    echo "release: $TAG was pushed, but creating the GitHub release failed. Create it with:" >&2
    printf '  gh release create %q --repo %q --title %q --notes-file %q --verify-tag\n' \
        "$TAG" "$REPO" "PRBar $VERSION" "$KEPT_NOTES" >&2
    exit 1
fi

echo
if (( DRY_RUN )); then
    echo "Dry run finished: nothing was changed, committed or pushed."
else
    echo "Released PRBar $VERSION: https://github.com/$REPO/releases/tag/$TAG"
fi
