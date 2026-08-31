#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.yaml"
MIRROR_CACHE_DIR="${MIRROR_CACHE_DIR:-$SCRIPT_DIR/.local/mirror-cache}"

MODE="update"
ACR_UNIQUEAPP_LOGGED_IN=false
ACR_UNIQUECR_LOGGED_IN=false

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

skopeo_source_reference() {
  local reference="$1"
  local tagged_reference digest image_name

  if [[ "$reference" != *@* ]]; then
    printf '%s' "$reference"
    return
  fi

  tagged_reference="${reference%@*}"
  digest="${reference##*@}"
  image_name="${tagged_reference##*/}"
  if [[ "$image_name" == *:* ]]; then
    tagged_reference="${tagged_reference%:*}"
  fi
  printf '%s@%s' "$tagged_reference" "$digest"
}

uses_plain_http() {
  local reference="$1"
  local registry

  registry="${reference#*://}"
  registry="${registry%%/*}"
  [[ "$registry" == "localhost" || "$registry" == localhost:* || "$registry" == *.localhost || "$registry" == *.localhost:* ]]
}

runtime_chart_repository() {
  local destination="$1"
  local mirror_registry runtime_registry

  mirror_registry="$(read_yaml '.harbor.registry')"
  runtime_registry="$(read_yaml '.harbor.runtimeRegistry')"
  printf '%s' "${destination/$mirror_registry/$runtime_registry}"
}

cache_marker_matches() {
  local marker_file="$1"
  local expected="$2"
  local actual

  if [ ! -f "$marker_file" ]; then
    return 1
  fi

  IFS= read -r actual <"$marker_file"
  [ "$actual" = "$expected" ]
}

login_acr() {
  local registry_name="$1"
  local registry="${registry_name}.azurecr.io"
  local token

  require_tool az
  token="$(az acr login --name "$registry_name" --expose-token --output tsv --query accessToken)"
  if [[ -z "$token" ]]; then
    printf 'Error: Azure registry token is empty for %s\n' "$registry" >&2
    exit 1
  fi

  printf 'Authenticating mirror tools with source registry %s\n' "$registry"
  printf '%s' "$token" | oras login -u 00000000-0000-0000-0000-000000000000 --password-stdin "$registry"
  printf '%s' "$token" | skopeo login -u 00000000-0000-0000-0000-000000000000 --password-stdin "$registry"
}

login_source_registry() {
  local reference="$1"
  local registry

  registry="${reference#*://}"
  registry="${registry%%/*}"
  case "$registry" in
    uniqueapp.azurecr.io)
      if [ "$ACR_UNIQUEAPP_LOGGED_IN" = false ]; then
        login_acr uniqueapp
        ACR_UNIQUEAPP_LOGGED_IN=true
      fi
      ;;
    uniquecr.azurecr.io)
      if [ "$ACR_UNIQUECR_LOGGED_IN" = false ]; then
        login_acr uniquecr
        ACR_UNIQUECR_LOGGED_IN=true
      fi
      ;;
  esac
}

login_harbor() {
  local registry password
  local -a helm_options=()
  local -a oras_options=()
  local -a skopeo_options=()

  registry="$(read_yaml '.harbor.registry')"
  if uses_plain_http "$registry"; then
    helm_options+=(--plain-http)
    oras_options+=(--plain-http)
    skopeo_options+=(--tls-verify=false)
  fi

  require_tool kubectl
  password="$(
    kubectl -n unique get secret harbor-password-secret -o json |
      yq -p=json -r '.data.HARBOR_ADMIN_PASSWORD | @base64d'
  )"
  if [[ -z "$password" ]]; then
    printf 'Error: Harbor admin password is empty\n' >&2
    exit 1
  fi

  printf 'Authenticating mirror tools with Harbor %s\n' "$registry"
  printf '%s' "$password" | oras login ${oras_options[@]+"${oras_options[@]}"} -u admin --password-stdin "$registry"
  printf '%s' "$password" | helm registry login ${helm_options[@]+"${helm_options[@]}"} -u admin --password-stdin "$registry"
  printf '%s' "$password" | skopeo login ${skopeo_options[@]+"${skopeo_options[@]}"} -u admin --password-stdin "$registry"
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

  local release mirror_registry image_project
  release="$(read_yaml '.release')"
  if [ -z "$release" ] || [ "$release" = "null" ]; then
    printf 'ERROR: versions.yaml must set .release\n' >&2
    exit 1
  fi
  mirror_registry="$(read_yaml '.harbor.registry')"
  image_project="$(read_yaml '.harbor.imageProject')"

  while IFS= read -r chart; do
    local source digest version destination runtime_file
    source="$(read_yaml ".charts.\"$chart\".source")"
    digest="$(read_yaml ".charts.\"$chart\".digest")"
    version="$(read_yaml ".charts.\"$chart\".version")"
    destination="$(read_yaml ".charts.\"$chart\".destination")"
    runtime_file="$(read_yaml ".charts.\"$chart\".runtimeFile")"

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

    if [ -z "$repo_url" ] || [ "$repo_url" = "null" ] || [ -z "$path" ] || [ "$path" = "null" ] || [ -z "$revision" ] || [ "$revision" = "null" ] || [ -z "$version" ] || [ "$version" = "null" ] || [ -z "$destination" ] || [ "$destination" = "null" ]; then
      printf 'ERROR: git chart %s must define repoURL, path, revision, version, and destination\n' "$chart" >&2
      exit 1
    fi
  done < <(git_chart_names)

  while IFS= read -r image; do
    local source destination expected_prefix
    source="$(read_yaml ".images.\"$image\".source")"
    destination="$(read_yaml ".images.\"$image\".destination")"

    if [ -z "$source" ] || [ "$source" = "null" ] || [ -z "$destination" ] || [ "$destination" = "null" ]; then
      printf 'ERROR: image %s must define source and destination\n' "$image" >&2
      exit 1
    fi

    case "$source" in
      docker://uniqueapp.azurecr.io/*|docker://uniquecr.azurecr.io/*)
        expected_prefix="docker://$mirror_registry/$image_project/"
        if [[ "$destination" != "$expected_prefix"* ]]; then
          printf 'ERROR: proprietary image %s destination must be under %s\n' "$image" "$expected_prefix" >&2
          exit 1
        fi
        ;;
    esac
  done < <(image_names)
}

copy_chart() {
  local chart="$1"
  local source destination version source_reference remote_reference cache_layout cache_source cache_key
  local -a destination_options=()
  source="$(read_yaml ".charts.\"$chart\".source")"
  destination="$(read_yaml ".charts.\"$chart\".destination")"
  version="$(read_yaml ".charts.\"$chart\".version")"
  source_reference="$(chart_source_reference "$chart")"
  cache_layout="$MIRROR_CACHE_DIR/charts/$chart"
  cache_source="$cache_layout/.source"
  cache_key="$source@$source_reference"

  if uses_plain_http "$destination"; then
    destination_options+=(--to-plain-http)
  fi

  if [[ "$source_reference" == sha256:* ]]; then
    remote_reference="$(strip_oci_scheme "$source")@${source_reference}"
  else
    remote_reference="$(strip_oci_scheme "$source"):${source_reference}"
  fi

  if [ ! -f "$cache_layout/index.json" ] || ! cache_marker_matches "$cache_source" "$cache_key"; then
    printf 'Caching chart %s from %s\n' "$chart" "$remote_reference"
    login_source_registry "$source"
    rm -rf "$cache_layout"
    mkdir -p "$(dirname "$cache_layout")"
    oras copy --to-oci-layout "$remote_reference" "$cache_layout:$version"
    printf '%s\n' "$cache_key" >"$cache_source"
  else
    printf 'Using cached chart %s\n' "$chart"
  fi

  printf 'Mirroring chart %s: local cache -> %s:%s\n' "$chart" "$destination" "$version"
  oras copy --from-oci-layout ${destination_options[@]+"${destination_options[@]}"} "$cache_layout:$version" "$(strip_oci_scheme "$destination"):${version}"
}

copy_image() {
  local image="$1"
  local source destination cache_layout cache_source skopeo_source
  local -a destination_options=()
  source="$(read_yaml ".images.\"$image\".source")"
  destination="$(read_yaml ".images.\"$image\".destination")"
  skopeo_source="$(skopeo_source_reference "$source")"
  cache_layout="$MIRROR_CACHE_DIR/images/$image"
  cache_source="$cache_layout/.source"

  if uses_plain_http "$destination"; then
    destination_options+=(--dest-tls-verify=false)
  fi

  if [ ! -f "$cache_layout/index.json" ] || ! cache_marker_matches "$cache_source" "$source"; then
    printf 'Caching image %s from %s\n' "$image" "$source"
    login_source_registry "$source"
    rm -rf "$cache_layout"
    mkdir -p "$(dirname "$cache_layout")"
    skopeo copy --all --preserve-digests "$skopeo_source" "oci:$cache_layout:cached"
    printf '%s\n' "$source" >"$cache_source"
  else
    printf 'Using cached image %s\n' "$image"
  fi

  printf 'Mirroring image %s: local cache -> %s\n' "$image" "$destination"
  skopeo copy --all --preserve-digests "oci:$cache_layout:cached" ${destination_options[@]+"${destination_options[@]}"} "$destination"
}

verify_chart() {
  local chart="$1"
  local destination digest version descriptor actual_digest
  local -a destination_options=()
  destination="$(read_yaml ".charts.\"$chart\".destination")"
  digest="$(read_yaml ".charts.\"$chart\".digest // \"\"")"
  version="$(read_yaml ".charts.\"$chart\".version")"

  if uses_plain_http "$destination"; then
    destination_options+=(--plain-http)
  fi

  printf 'Verifying chart %s at %s:%s\n' "$chart" "$destination" "$version"
  descriptor="$(oras manifest fetch ${destination_options[@]+"${destination_options[@]}"} --descriptor "$(strip_oci_scheme "$destination"):${version}")"
  actual_digest="$(printf '%s' "$descriptor" | yq -p=json -r '.digest')"

  if [ -n "$digest" ] && [ "$actual_digest" != "$digest" ]; then
    printf 'ERROR: chart %s destination digest %s does not match expected %s\n' "$chart" "$actual_digest" "$digest" >&2
    exit 1
  fi

  yq -i ".charts.\"$chart\".digest = \"$actual_digest\"" "$VERSIONS_FILE"
}

mirror_git_chart() {
  local chart="$1"
  local repo_url path revision version destination cache_dir package_file cache_source cache_key
  local work_dir chart_name chart_version built_package descriptor digest
  local -a helm_destination_options=()
  local -a oras_destination_options=()
  repo_url="$(read_yaml ".gitCharts.\"$chart\".repoURL")"
  path="$(read_yaml ".gitCharts.\"$chart\".path")"
  revision="$(read_yaml ".gitCharts.\"$chart\".revision")"
  version="$(read_yaml ".gitCharts.\"$chart\".version")"
  destination="$(read_yaml ".gitCharts.\"$chart\".destination")"
  cache_dir="$MIRROR_CACHE_DIR/git-charts"
  package_file="$cache_dir/$chart-$version.tgz"
  cache_source="$package_file.source"
  cache_key="$repo_url|$path|$revision|$version"

  if uses_plain_http "$destination"; then
    helm_destination_options+=(--plain-http)
    oras_destination_options+=(--plain-http)
  fi

  if [ ! -f "$package_file" ] || ! cache_marker_matches "$cache_source" "$cache_key"; then
    printf 'Packaging and caching git chart %s from %s at %s\n' "$chart" "$repo_url" "$revision"
    require_tool git
    work_dir="$(mktemp -d)"
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
    built_package="$work_dir/${chart_name}-${chart_version}.tgz"

    if [ ! -f "$built_package" ]; then
      printf 'ERROR: failed to package git chart %s\n' "$chart" >&2
      rm -rf "$work_dir"
      exit 1
    fi

    mkdir -p "$cache_dir"
    mv "$built_package" "$package_file"
    printf '%s\n' "$cache_key" >"$cache_source"
    rm -rf "$work_dir"
  else
    printf 'Using cached git chart %s\n' "$chart"
  fi

  helm push ${helm_destination_options[@]+"${helm_destination_options[@]}"} "$package_file" "oci://$(strip_oci_scheme "${destination%/*}")"
  descriptor="$(oras manifest fetch ${oras_destination_options[@]+"${oras_destination_options[@]}"} --descriptor "$(strip_oci_scheme "$destination"):${version}")"
  digest="$(printf '%s' "$descriptor" | yq -p=json -r '.digest')"
  yq -i ".gitCharts.\"$chart\".digest = \"$digest\"" "$VERSIONS_FILE"
}

update_runtime_chart_specs() {
  while IFS= read -r chart; do
    local runtime_file destination target_revision
    runtime_file="$(read_yaml ".charts.\"$chart\".runtimeFile // \"\"")"
    if [[ -z "$runtime_file" ]]; then
      continue
    fi
    destination="$(runtime_chart_repository "$(read_yaml ".charts.\"$chart\".destination")")"
    target_revision="$(chart_source_reference "$chart")"
    require_file "$SCRIPT_DIR/$runtime_file"

    if [ "$MODE" = "dry-run" ]; then
      yq ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
    else
      yq -i ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file"
    fi
  done < <(chart_names)
}

update_git_chart_specs() {
  while IFS= read -r chart; do
    local runtime_file destination target_revision
    runtime_file="$(read_yaml ".gitCharts.\"$chart\".runtimeFile // \"\"")"
    if [[ -z "$runtime_file" ]]; then
      continue
    fi
    destination="$(runtime_chart_repository "$(read_yaml ".gitCharts.\"$chart\".destination")")"
    target_revision="$(git_chart_target_revision "$chart")"
    require_file "$SCRIPT_DIR/$runtime_file"

    if [ "$MODE" = "dry-run" ]; then
      yq ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file" >/dev/null
    else
      yq -i ".spec.source.repoURL = \"$destination\" | .spec.source.targetRevision = \"$target_revision\" | .spec.source.path = \".\"" "$SCRIPT_DIR/$runtime_file"
    fi
  done < <(git_chart_names)
}

validate_runtime_references() {
  while IFS= read -r chart; do
    local runtime_file expected_repo expected_revision actual_repo actual_revision
    runtime_file="$(read_yaml ".charts.\"$chart\".runtimeFile // \"\"")"
    if [[ -z "$runtime_file" ]]; then
      continue
    fi
    expected_repo="$(runtime_chart_repository "$(read_yaml ".charts.\"$chart\".destination")")"
    expected_revision="$(chart_source_reference "$chart")"
    actual_repo="$(yq -r '.spec.source.repoURL' "$SCRIPT_DIR/$runtime_file")"
    actual_revision="$(yq -r '.spec.source.targetRevision' "$SCRIPT_DIR/$runtime_file")"

    if [ "$actual_repo" != "$expected_repo" ] || [ "$actual_revision" != "$expected_revision" ]; then
      printf 'ERROR: chart %s runtime reference mismatch in %s\n' "$chart" "$runtime_file" >&2
      exit 1
    fi
  done < <(chart_names)

  while IFS= read -r chart; do
    local runtime_file expected_repo expected_revision actual_repo actual_revision
    runtime_file="$(read_yaml ".gitCharts.\"$chart\".runtimeFile // \"\"")"
    if [[ -z "$runtime_file" ]]; then
      continue
    fi
    expected_repo="$(runtime_chart_repository "$(read_yaml ".gitCharts.\"$chart\".destination")")"
    expected_revision="$(git_chart_target_revision "$chart")"
    actual_repo="$(yq -r '.spec.source.repoURL' "$SCRIPT_DIR/$runtime_file")"
    actual_revision="$(yq -r '.spec.source.targetRevision' "$SCRIPT_DIR/$runtime_file")"

    if [ "$actual_repo" != "$expected_repo" ] || [ "$actual_revision" != "$expected_revision" ]; then
      printf 'ERROR: git chart %s runtime reference mismatch in %s\n' "$chart" "$runtime_file" >&2
      exit 1
    fi
  done < <(git_chart_names)
}

validate_isolated_runtime_sources() {
  local forbidden_pattern='Unique-AG/(monorepo|connectors)|uniqueapp\.azurecr\.io|uniquecr\.azurecr\.io'

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
    require_tool helm
    login_harbor

    while IFS= read -r chart; do
      copy_chart "$chart"
      verify_chart "$chart"
    done < <(chart_names)

    while IFS= read -r chart; do
      mirror_git_chart "$chart"
    done < <(git_chart_names)

    while IFS= read -r image; do
      copy_image "$image"
    done < <(image_names)

    update_runtime_chart_specs
    update_git_chart_specs
    validate_runtime_references
    validate_isolated_runtime_sources
    ;;
  update)
    update_runtime_chart_specs
    update_git_chart_specs
    validate_runtime_references
    validate_isolated_runtime_sources
    ;;
  dry-run)
    update_runtime_chart_specs
    update_git_chart_specs
    validate_runtime_references
    validate_isolated_runtime_sources
    ;;
  validate)
    validate_runtime_references
    validate_isolated_runtime_sources
    ;;
esac

printf 'Version workflow completed in %s mode.\n' "$MODE"