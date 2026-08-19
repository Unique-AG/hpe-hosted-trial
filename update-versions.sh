#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.yaml"
APP_ELEMENTS_FILE="$SCRIPT_DIR/2-applications/elements/apps.elements.yaml"
COMPONENT_SPECS_DIR="$SCRIPT_DIR/2-applications/elements/apps"
APPLICATION_SPECS_DIR="$SCRIPT_DIR/2-applications/application-specs"

MODE="update"

usage() {
  printf 'Usage: %s [--update|--mirror|--validate|--dry-run]\n' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update)
      MODE="update"
      ;;
    --mirror)
      MODE="mirror"
      ;;
    --validate)
      MODE="validate"
      ;;
    --dry-run)
      MODE="dry-run"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_tool() {
  local tool="$1"

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'ERROR: required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
}

require_file() {
  local file="$1"

  if [ ! -f "$file" ]; then
    printf 'ERROR: required file not found: %s\n' "$file" >&2
    exit 1
  fi
}

read_yaml() {
  yq -r "$1" "$VERSIONS_FILE"
}

chart_names() {
  yq -r '.charts | keys | .[]' "$VERSIONS_FILE"
}

image_names() {
  yq -r '.images // {} | keys | .[]' "$VERSIONS_FILE"
}

git_chart_names() {
  yq -r '.gitCharts // {} | keys | .[]' "$VERSIONS_FILE"
}

strip_oci_scheme() {
  printf '%s' "${1#oci://}"
}

chart_source_reference() {
  local chart="$1"
  local digest version
  digest="$(read_yaml ".charts.\"$chart\".digest // \"\"")"
  version="$(read_yaml ".charts.\"$chart\".version")"

  if [ -n "$digest" ]; then
    printf '%s' "$digest"
  else
    printf '%s' "$version"
  fi
}

git_chart_target_revision() {
  local chart="$1"
  local digest version
  digest="$(read_yaml ".gitCharts.\"$chart\".digest // \"\"")"
  version="$(read_yaml ".gitCharts.\"$chart\".version")"

  if [ -n "$digest" ]; then
    printf '%s' "$digest"
  else
    printf '%s' "$version"
  fi
}

validate_versions_file() {
  require_file "$VERSIONS_FILE"

  local release
  release="$(read_yaml '.release')"
  if [ -z "$release" ] || [ "$release" = "null" ]; then
    printf 'ERROR: versions.yaml must set .release\n' >&2
    exit 1
  fi

  while IFS= read -r chart; do
    local source digest version destination
    source="$(read_yaml ".charts.\"$chart\".source")"
    digest="$(read_yaml ".charts.\"$chart\".digest")"
    version="$(read_yaml ".charts.\"$chart\".version")"
    destination="$(read_yaml ".charts.\"$chart\".destination")"

    if [ -z "$source" ] || [ "$source" = "null" ] || [ -z "$version" ] || [ "$version" = "null" ] || [ -z "$destination" ] || [ "$destination" = "null" ]; then
      printf 'ERROR: chart %s must define source, version, and destination\n' "$chart" >&2
      exit 1
    fi

    if [ -n "$digest" ] && [ "$digest" != "null" ]; then
      case "$digest" in
        sha256:*) ;;
        *)
        printf 'ERROR: chart %s digest must be a sha256 digest\n' "$chart" >&2
        exit 1
          ;;
      esac
    fi
  done < <(chart_names)

  while IFS= read -r chart; do
    local repo_url path revision version destination runtime_file
    repo_url="$(read_yaml ".gitCharts.\"$chart\".repoURL")"
    path="$(read_yaml ".gitCharts.\"$chart\".path")"
    revision="$(read_yaml ".gitCharts.\"$chart\".revision")"
    version="$(read_yaml ".gitCharts.\"$chart\".version")"
    destination="$(read_yaml ".gitCharts.\"$chart\".destination")"
    runtime_file="$(read_yaml ".gitCharts.\"$chart\".runtimeFile")"

    if [ -z "$repo_url" ] || [ "$repo_url" = "null" ] || [ -z "$path" ] || [ "$path" = "null" ] || [ -z "$revision" ] || [ "$revision" = "null" ] || [ -z "$version" ] || [ "$version" = "null" ] || [ -z "$destination" ] || [ "$destination" = "null" ] || [ -z "$runtime_file" ] || [ "$runtime_file" = "null" ]; then
      printf 'ERROR: git chart %s must define repoURL, path, revision, version, destination, and runtimeFile\n' "$chart" >&2
      exit 1
    fi
  done < <(git_chart_names)

  while IFS= read -r image; do
    local source destination
    source="$(read_yaml ".images.\"$image\".source")"
    destination="$(read_yaml ".images.\"$image\".destination")"

    if [ -z "$source" ] || [ "$source" = "null" ] || [ -z "$destination" ] || [ "$destination" = "null" ]; then
      printf 'ERROR: image %s must define source and destination\n' "$image" >&2
      exit 1
    fi
  done < <(image_names)
}

copy_chart() {
  local chart="$1"
  local source destination version source_reference
  source="$(read_yaml ".charts.\"$chart\".source")"
  destination="$(read_yaml ".charts.\"$chart\".destination")"
  version="$(read_yaml ".charts.\"$chart\".version")"
  source_reference="$(chart_source_reference "$chart")"

  printf 'Mirroring chart %s: %s@%s -> %s:%s\n' "$chart" "$source" "$source_reference" "$destination" "$version"
  if [[ "$source_reference" == sha256:* ]]; then
    oras copy "$(strip_oci_scheme "$source")@${source_reference}" "$(strip_oci_scheme "$destination"):${version}"
  else
    oras copy "$(strip_oci_scheme "$source"):${source_reference}" "$(strip_oci_scheme "$destination"):${version}"
  fi
}

copy_image() {
  local image="$1"
  local source destination
  source="$(read_yaml ".images.\"$image\".source")"
  destination="$(read_yaml ".images.\"$image\".destination")"

  printf 'Mirroring image %s: %s -> %s\n' "$image" "$source" "$destination"
  skopeo copy --all "$source" "$destination"
}

verify_chart() {
  local chart="$1"
  local destination digest version descriptor actual_digest
  destination="$(read_yaml ".charts.\"$chart\".destination")"
  digest="$(read_yaml ".charts.\"$chart\".digest // \"\"")"
  version="$(read_yaml ".charts.\"$chart\".version")"

  printf 'Verifying chart %s at %s:%s\n' "$chart" "$destination" "$version"
  descriptor="$(oras manifest fetch --descriptor "$(strip_oci_scheme "$destination"):${version}")"
  actual_digest="$(printf '%s' "$descriptor" | yq -p=json -r '.digest')"

  if [ -n "$digest" ] && [ "$actual_digest" != "$digest" ]; then
    printf 'ERROR: chart %s destination digest %s does not match expected %s\n' "$chart" "$actual_digest" "$digest" >&2
    exit 1
  fi

  yq -i ".charts.\"$chart\".digest = \"$actual_digest\"" "$VERSIONS_FILE"
}

mirror_git_chart() {
  local chart="$1"
  local repo_url path revision version destination work_dir chart_name chart_version package_file descriptor digest
  repo_url="$(read_yaml ".gitCharts.\"$chart\".repoURL")"
  path="$(read_yaml ".gitCharts.\"$chart\".path")"
  revision="$(read_yaml ".gitCharts.\"$chart\".revision")"
  version="$(read_yaml ".gitCharts.\"$chart\".version")"
  destination="$(read_yaml ".gitCharts.\"$chart\".destination")"
  work_dir="$(mktemp -d)"

  printf 'Packaging git chart %s from %s at %s\n' "$chart" "$repo_url" "$revision"
  git clone --filter=blob:none --no-checkout "$repo_url" "$work_dir/repository" >/dev/null
  git -C "$work_dir/repository" fetch --depth 1 origin "$revision" >/dev/null
  git -C "$work_dir/repository" checkout --detach FETCH_HEAD >/dev/null
  helm dependency build "$work_dir/repository/$path"
  chart_name="$(helm show chart "$work_dir/repository/$path" | yq -r '.name')"
  chart_version="$(helm show chart "$work_dir/repository/$path" | yq -r '.version')"

  if [ "$chart_version" != "$version" ]; then
    printf 'ERROR: git chart %s version %s does not match configured version %s\n' "$chart" "$chart_version" "$version" >&2
    rm -rf "$work_dir"
    exit 1
  fi

  helm package "$work_dir/repository/$path" --destination "$work_dir" >/dev/null
  package_file="$work_dir/${chart_name}-${chart_version}.tgz"

  if [ -z "$package_file" ] || [ ! -f "$package_file" ]; then
    printf 'ERROR: failed to package git chart %s\n' "$chart" >&2
    rm -rf "$work_dir"
    exit 1
  fi

  helm push "$package_file" "oci://$(strip_oci_scheme "${destination%/*}")"
  descriptor="$(oras manifest fetch --descriptor "$(strip_oci_scheme "$destination"):${version}")"
  digest="$(printf '%s' "$descriptor" | yq -p=json -r '.digest')"
  yq -i ".gitCharts.\"$chart\".digest = \"$digest\"" "$VERSIONS_FILE"
  rm -rf "$work_dir"
}

update_app_elements() {
  require_file "$APP_ELEMENTS_FILE"

  local expression='.'
  while IFS= read -r chart; do
    local destination digest version
    destination="$(read_yaml ".charts.\"$chart\".destination")"
    digest="$(read_yaml ".charts.\"$chart\".digest")"
    version="$(read_yaml ".charts.\"$chart\".version")"

    expression="$expression | (.components[] | select(.app == \"$chart\") | .repoURL) = \"$destination\""
    expression="$expression | (.components[] | select(.app == \"$chart\") | .targetRevision) = \"$digest\""
    expression="$expression | (.components[] | select(.app == \"$chart\") | .chartVersion) = \"$version\""
  done < <(chart_names)

  if [ "$MODE" = "dry-run" ]; then
    yq "$expression" "$APP_ELEMENTS_FILE" >/dev/null
  else
    yq -i "$expression" "$APP_ELEMENTS_FILE"
  fi
}

update_full_specs() {
  if [ ! -d "$APPLICATION_SPECS_DIR" ]; then
    return
  fi

  while IFS= read -r chart; do
    local destination digest
    destination="$(read_yaml ".charts.\"$chart\".destination")"
    digest="$(read_yaml ".charts.\"$chart\".digest")"

    while IFS= read -r app_file; do
      if [ "$MODE" = "dry-run" ]; then
        yq "(.spec.sources[] | select(.repoURL == \"$(read_yaml ".charts.\"$chart\".source")\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$digest\"" "$app_file" >/dev/null
      else
        yq -i "(.spec.sources[] | select(.repoURL == \"$(read_yaml ".charts.\"$chart\".source")\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$digest\"" "$app_file"
      fi
    done < <(find "$APPLICATION_SPECS_DIR" -name app.yaml -type f)
  done < <(chart_names)
}

update_component_specs() {
  if [ ! -d "$COMPONENT_SPECS_DIR" ]; then
    return
  fi

  while IFS= read -r chart; do
    local app_file destination digest version
    app_file="$COMPONENT_SPECS_DIR/$chart.yaml"
    destination="$(read_yaml ".charts.\"$chart\".destination")"
    digest="$(read_yaml ".charts.\"$chart\".digest")"
    version="$(read_yaml ".charts.\"$chart\".version")"

    if [ ! -f "$app_file" ]; then
      continue
    fi

    if [ "$MODE" = "dry-run" ]; then
      yq "(.spec.sources[] | select(.path == \".\" and has(\"helm\")) | .repoURL) = \"$destination\" | (.spec.sources[] | select(.path == \".\" and has(\"helm\")) | .targetRevision) = \"$digest\"" "$app_file" >/dev/null
    else
      yq -i "(.spec.sources[] | select(.path == \".\" and has(\"helm\")) | .repoURL) = \"$destination\" | (.spec.sources[] | select(.path == \".\" and has(\"helm\")) | .targetRevision) = \"$digest\"" "$app_file"
    fi

    if [ "$MODE" != "dry-run" ]; then
      yq -i "(.spec.chartVersion) = \"$version\"" "$app_file"
    fi
  done < <(chart_names)
}

update_runtime_chart_specs() {
  while IFS= read -r chart; do
    local runtime_file source destination target_revision
    runtime_file="$(read_yaml ".charts.\"$chart\".runtimeFile // \"\"")"
    if [ -z "$runtime_file" ]; then
      continue
    fi

    source="$(read_yaml ".charts.\"$chart\".source")"
    destination="$(read_yaml ".charts.\"$chart\".destination")"
    target_revision="$(chart_source_reference "$chart")"
    require_file "$SCRIPT_DIR/$runtime_file"

    if [ "$(yq -r '.spec.source != null' "$SCRIPT_DIR/$runtime_file")" = "true" ]; then
      if [ "$MODE" = "dry-run" ]; then
        yq ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
      else
        yq -i ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file"
      fi
    elif [ "$MODE" = "dry-run" ]; then
      yq "(.spec.sources[] | select(.repoURL == \"$source\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$target_revision\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .path) = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
    else
      yq -i "(.spec.sources[] | select(.repoURL == \"$source\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$target_revision\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .path) = \".\"" "$SCRIPT_DIR/$runtime_file"
    fi
  done < <(chart_names)
}

update_git_chart_specs() {
  while IFS= read -r chart; do
    local runtime_file source destination target_revision
    runtime_file="$(read_yaml ".gitCharts.\"$chart\".runtimeFile")"
    source="$(read_yaml ".gitCharts.\"$chart\".repoURL")"
    destination="$(read_yaml ".gitCharts.\"$chart\".destination")"
    target_revision="$(git_chart_target_revision "$chart")"
    require_file "$SCRIPT_DIR/$runtime_file"

    if [ "$(yq -r '.spec.source != null' "$SCRIPT_DIR/$runtime_file")" = "true" ]; then
      if [ "$MODE" = "dry-run" ]; then
        yq ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
      else
        yq -i ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file"
      fi
    elif [ "$MODE" = "dry-run" ]; then
      yq "(.spec.sources[] | select(.repoURL == \"$source\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$target_revision\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .path) = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
    else
      yq -i "(.spec.sources[] | select(.repoURL == \"$source\") | .repoURL) = \"$destination\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .targetRevision) = \"$target_revision\" | (.spec.sources[] | select(.repoURL == \"$destination\") | .path) = \".\"" "$SCRIPT_DIR/$runtime_file"
    fi
  done < <(git_chart_names)
}

validate_generated_references() {
  if [ -f "$APP_ELEMENTS_FILE" ]; then
    while IFS= read -r chart; do
      local expected_repo expected_digest actual_repo actual_digest
      expected_repo="$(read_yaml ".charts.\"$chart\".destination")"
      expected_digest="$(read_yaml ".charts.\"$chart\".digest")"
      actual_repo="$(yq -r "(.components[] | select(.app == \"$chart\") | .repoURL) // \"\"" "$APP_ELEMENTS_FILE")"
      actual_digest="$(yq -r "(.components[] | select(.app == \"$chart\") | .targetRevision) // \"\"" "$APP_ELEMENTS_FILE")"

      if [ -n "$actual_repo" ] && { [ "$actual_repo" != "$expected_repo" ] || [ "$actual_digest" != "$expected_digest" ]; }; then
        printf 'ERROR: %s reference mismatch in apps.elements.yaml\n' "$chart" >&2
        exit 1
      fi
    done < <(chart_names)
  fi
}

validate_isolated_runtime_sources() {
  local forbidden_pattern='Unique-AG/(monorepo|connectors)|uniqueapp\\.azurecr\\.io|uniquecr\\.azurecr\\.io|ghcr\\.io/unique-ag'

  if rg -n "$forbidden_pattern" "$SCRIPT_DIR/1-system" "$SCRIPT_DIR/2-applications" --glob '*.yaml'; then
    printf 'ERROR: runtime manifests contain Unique-owned external sources\n' >&2
    exit 1
  fi
}

require_tool yq
require_tool rg
validate_versions_file

case "$MODE" in
  mirror)
    require_tool oras
    require_tool skopeo

    while IFS= read -r chart; do
      copy_chart "$chart"
      verify_chart "$chart"
    done < <(chart_names)

    require_tool git
    require_tool helm
    while IFS= read -r chart; do
      mirror_git_chart "$chart"
    done < <(git_chart_names)

    while IFS= read -r image; do
      copy_image "$image"
    done < <(image_names)

    update_app_elements
    update_component_specs
    update_full_specs
    update_runtime_chart_specs
    update_git_chart_specs
    validate_generated_references
    validate_isolated_runtime_sources
    ;;
  update)
    update_app_elements
    update_component_specs
    update_full_specs
    update_runtime_chart_specs
    update_git_chart_specs
    validate_generated_references
    validate_isolated_runtime_sources
    ;;
  dry-run)
    update_app_elements
    update_component_specs
    update_full_specs
    update_runtime_chart_specs
    update_git_chart_specs
    validate_generated_references
    validate_isolated_runtime_sources
    ;;
  validate)
    validate_generated_references
    validate_isolated_runtime_sources
    ;;
esac

printf 'Version workflow completed in %s mode.\n' "$MODE"