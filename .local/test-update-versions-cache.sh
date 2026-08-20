#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

FIXTURE_DIR="$TEST_DIR/fixture"
MOCK_BIN="$TEST_DIR/bin"
COMMAND_LOG="$TEST_DIR/commands.log"
mkdir -p "$FIXTURE_DIR" "$MOCK_BIN"
cp "$REPOSITORY_DIR/update-versions.sh" "$FIXTURE_DIR/update-versions.sh"

cat >"$FIXTURE_DIR/versions.yaml" <<'EOF'
release: test
harbor:
  registry: harbor.localhost
  runtimeRegistry: harbor.unique.svc.cluster.local
  imageProject: library/images
charts:
  sample-chart:
    source: oci://uniqueapp.azurecr.io/helm/sample
    digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    version: 1.0.0
    destination: oci://harbor.localhost/library/helm/sample
gitCharts:
  sample-git-chart:
    repoURL: git@example.invalid:charts.git
    path: deploy/chart
    revision: v2.0.0
    version: 2.0.0
    destination: oci://harbor.localhost/library/helm/sample-git
images:
  sample:
    source: docker://uniqueapp.azurecr.io/example/sample:1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    destination: docker://harbor.localhost/library/images/sample:1
EOF

cat >"$MOCK_BIN/az" <<'EOF'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >>"$COMMAND_LOG"
printf 'token\n'
EOF

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '{"data":{"HARBOR_ADMIN_PASSWORD":"cGFzc3dvcmQ="}}\n'
EOF

cat >"$MOCK_BIN/oras" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ]; then
  read -r _ || true
  exit 0
fi

if [ "${1:-}" = "manifest" ]; then
  printf '{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
  exit 0
fi

printf 'oras %s\n' "$*" >>"$COMMAND_LOG"
destination=""
for argument in "$@"; do
  destination="$argument"
done

case "$destination" in
  *mirror-cache/charts/*:*)
    layout="${destination%:*}"
    mkdir -p "$layout"
    printf '{}\n' >"$layout/index.json"
    ;;
esac
EOF

cat >"$MOCK_BIN/helm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "registry" ] && [ "${2:-}" = "login" ]; then
  read -r _ || true
  exit 0
fi

printf 'helm %s\n' "$*" >>"$COMMAND_LOG"
case "${1:-} ${2:-}" in
  "dependency build")
    ;;
  "show chart")
    printf 'name: sample-git\nversion: 2.0.0\n'
    ;;
  "package "*)
    destination=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "--destination" ]; then
        destination="$argument"
      fi
      previous="$argument"
    done
    : >"$destination/sample-git-2.0.0.tgz"
    ;;
  "push "*)
    ;;
esac
EOF

cat >"$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$COMMAND_LOG"
if [ "${1:-}" = "clone" ]; then
  destination=""
  for argument in "$@"; do
    destination="$argument"
  done
  mkdir -p "$destination/deploy/chart"
fi
EOF

cat >"$MOCK_BIN/rg" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"$MOCK_BIN/skopeo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ]; then
  read -r _ || true
  exit 0
fi

printf 'skopeo %s\n' "$*" >>"$COMMAND_LOG"
destination=""
for argument in "$@"; do
  destination="$argument"
done

case "$destination" in
  oci:*)
    layout_reference="${destination#oci:}"
    layout="${layout_reference%:*}"
    mkdir -p "$layout"
    printf '{}\n' >"$layout/index.json"
    ;;
esac
EOF

chmod +x "$MOCK_BIN"/*
export COMMAND_LOG
export PATH="$MOCK_BIN:$PATH"

"$FIXTURE_DIR/update-versions.sh" --mirror

CACHE_LAYOUT="$FIXTURE_DIR/.local/mirror-cache/images/sample"
if [ ! -f "$CACHE_LAYOUT/index.json" ]; then
  printf 'FAIL: first mirror did not populate the image cache\n' >&2
  exit 1
fi

FIRST_COMMANDS="$(<"$COMMAND_LOG")"
if [[ "$FIRST_COMMANDS" != *"skopeo copy --all --preserve-digests docker://uniqueapp.azurecr.io/example/sample@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb oci:$CACHE_LAYOUT:cached"* ]]; then
  printf 'FAIL: tagged digest source was not normalized for Skopeo\n' >&2
  exit 1
fi

CHART_CACHE_LAYOUT="$FIXTURE_DIR/.local/mirror-cache/charts/sample-chart"
if [ ! -f "$CHART_CACHE_LAYOUT/index.json" ]; then
  printf 'FAIL: first mirror did not populate the chart cache\n' >&2
  exit 1
fi

GIT_CHART_CACHE="$FIXTURE_DIR/.local/mirror-cache/git-charts/sample-git-chart-2.0.0.tgz"
if [ ! -f "$GIT_CHART_CACHE" ]; then
  printf 'FAIL: first mirror did not populate the Git chart cache\n' >&2
  exit 1
fi

: >"$COMMAND_LOG"
"$FIXTURE_DIR/update-versions.sh" --mirror

COMMANDS="$(<"$COMMAND_LOG")"
if [[ "$COMMANDS" != *"oras copy --from-oci-layout --to-plain-http $CHART_CACHE_LAYOUT:1.0.0 harbor.localhost/library/helm/sample:1.0.0"* ]]; then
  printf 'FAIL: second mirror did not restore the chart from the cache\n' >&2
  exit 1
fi

if [[ "$COMMANDS" != *"helm push --plain-http $GIT_CHART_CACHE oci://harbor.localhost/library/helm"* ]]; then
  printf 'FAIL: second mirror did not restore the Git chart from the cache\n' >&2
  exit 1
fi

if [[ "$COMMANDS" == git\ * || "$COMMANDS" == *$'\ngit '* ]]; then
  printf 'FAIL: Git chart cache hit fetched the source repository\n' >&2
  exit 1
fi

if [[ "$COMMANDS" != *"skopeo copy --all --preserve-digests oci:$CACHE_LAYOUT:cached --dest-tls-verify=false docker://harbor.localhost/library/images/sample:1"* ]]; then
  printf 'FAIL: second mirror did not restore the image from the cache\n' >&2
  exit 1
fi

if [[ "$COMMANDS" == az\ * || "$COMMANDS" == *$'\naz '* ]]; then
  printf 'FAIL: cache hit authenticated with the source registry\n' >&2
  exit 1
fi

yq -i '.images.sample.destination = "docker://harbor.localhost/other/sample:1"' "$FIXTURE_DIR/versions.yaml"
if "$FIXTURE_DIR/update-versions.sh" --validate >/dev/null 2>&1; then
  printf 'FAIL: validation accepted a proprietary image outside library/images\n' >&2
  exit 1
fi

printf 'PASS: mirror caches are reused\n'
