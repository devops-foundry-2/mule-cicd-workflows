#!/usr/bin/env bash
# ci-shim.sh — portable CI abstraction for the core/ci scripts (Azure DevOps + GitHub Actions).
#
# Source it; never execute it:   source "$(dirname "${BASH_SOURCE[0]}")/lib/ci-shim.sh"
#
# Safe to source: sets NO shell options (no set -e/-u/-o pipefail), never exits, defines functions
# only, and is idempotent. The extracted scripts keep exactly the error-handling mode their Azure
# inline source had; the shim must not change it.
#
# Platform detection (override by exporting CI_PLATFORM=github|ado|local before sourcing):
#   github  GITHUB_ACTIONS=true
#   ado     TF_BUILD=True (set by every Azure Pipelines agent) or ADO=true
#   local   anything else (plain stderr logging, outputs exported into the current process)
#
# On ado the emitted logging commands are byte-identical to the ##vso[...] lines the Azure inline
# templates print, so a script run under Azure behaves exactly like its inline source.

if [[ -n "${__MDF_CI_SHIM_LOADED:-}" ]]; then
  # shellcheck disable=SC2317  # the fallback only runs if the file is (wrongly) executed
  return 0 2>/dev/null || true
fi
__MDF_CI_SHIM_LOADED=1

if [[ -z "${CI_PLATFORM:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    CI_PLATFORM="github"
  elif [[ -n "${TF_BUILD:-}" || "${ADO:-}" == "true" ]]; then
    CI_PLATFORM="ado"
  else
    CI_PLATFORM="local"
  fi
fi

# GitHub workflow-command data escaping (same rules as @actions/core).
_ci_gh_escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

# Append NAME=VALUE to a GitHub file command ($GITHUB_OUTPUT / $GITHUB_ENV) using the multiline
# delimiter form, so values containing newlines are carried intact.
_ci_gh_file_cmd() {
  local file="$1" name="$2" val="$3" delim
  [[ -n "$file" ]] || return 0
  delim="__MDF_EOF_${RANDOM}${RANDOM}${RANDOM}__"
  while [[ "$val" == *"$delim"* ]]; do
    delim="__MDF_EOF_${RANDOM}${RANDOM}${RANDOM}__"
  done
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$val"
    printf '%s\n' "$delim"
  } >> "$file"
}

ci_log_error() {
  case "$CI_PLATFORM" in
    github) echo "::error::$(_ci_gh_escape "$1")" ;;
    ado)    echo "##vso[task.logissue type=error]$1" ;;
    *)      echo "ERROR: $1" >&2 ;;
  esac
}

ci_log_warning() {
  case "$CI_PLATFORM" in
    github) echo "::warning::$(_ci_gh_escape "$1")" ;;
    ado)    echo "##vso[task.logissue type=warning]$1" ;;
    *)      echo "WARNING: $1" >&2 ;;
  esac
}

# Mask a runtime-produced value in logs (GitHub only; Azure has no standalone equivalent).
ci_mask() {
  local line
  [[ "$CI_PLATFORM" == "github" && -n "$1" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "::add-mask::${line}"
  done <<< "$1"
}

# Step OUTPUT variable (Azure isOutput=true / GitHub $GITHUB_OUTPUT). On GitHub the file is
# $CI_OUTPUT_FILE when set (run-ci-script collects it into a JSON output), else $GITHUB_OUTPUT.
ci_set_var() {
  local name="$1" val="$2"
  case "$CI_PLATFORM" in
    github) _ci_gh_file_cmd "${CI_OUTPUT_FILE:-${GITHUB_OUTPUT:-}}" "$name" "$val" ;;
    ado)    echo "##vso[task.setvariable variable=${name};isOutput=true]${val}" ;;
    *)      export "${name}=${val}" ;;
  esac
}

ci_set_secret_var() {
  local name="$1" val="$2"
  case "$CI_PLATFORM" in
    github)
      ci_mask "$val"
      _ci_gh_file_cmd "${CI_OUTPUT_FILE:-${GITHUB_OUTPUT:-}}" "$name" "$val"
      ;;
    ado)    echo "##vso[task.setvariable variable=${name};isOutput=true;issecret=true]${val}" ;;
    *)      export "${name}=${val}" ;;
  esac
}

# Job-scoped variable for LATER steps of the same job (Azure setvariable without isOutput /
# GitHub $GITHUB_ENV). Also exported into the current process.
ci_set_env() {
  local name="$1" val="$2"
  export "${name}=${val}"
  case "$CI_PLATFORM" in
    github) _ci_gh_file_cmd "${GITHUB_ENV:-}" "$name" "$val" ;;
    ado)    echo "##vso[task.setvariable variable=${name}]${val}" ;;
    *)      ;;
  esac
}

# Azure ##vso[task.complete result=...]. GitHub has no "succeeded with issues" job state; the
# closest faithful signal is an annotation of the matching severity.
ci_complete_with_issues() {
  case "$CI_PLATFORM" in
    github) echo "::warning::$(_ci_gh_escape "$1")" ;;
    ado)    echo "##vso[task.complete result=SucceededWithIssues;]$1" ;;
    *)      echo "WARNING: $1" >&2 ;;
  esac
}

ci_complete_failed() {
  case "$CI_PLATFORM" in
    github) echo "::error::$(_ci_gh_escape "$1")" ;;
    ado)    echo "##vso[task.complete result=Failed;]$1" ;;
    *)      echo "ERROR: $1" >&2 ;;
  esac
}

ci_group_start() {
  case "$CI_PLATFORM" in
    github) echo "::group::$1" ;;
    ado)    echo "##[group]$1" ;;
    *)      echo "=== $1 ===" ;;
  esac
}

ci_group_end() {
  case "$CI_PLATFORM" in
    github) echo "::endgroup::" ;;
    ado)    echo "##[endgroup]" ;;
    *)      ;;
  esac
}

# ── Predefined-variable normalizers (one per Azure macro the templates use) ──────────────────────
# $(Pipeline.Workspace). GitHub has no equivalent root, so the workflows use $RUNNER_TEMP/pw with
# pw/s linked to $GITHUB_WORKSPACE (run-ci-script sets this up), keeping the Azure-relative paths
# (s/env-settings, mule-artifacts, build-metadata, .m2/repository) valid unchanged.
ci_pipeline_workspace() {
  case "$CI_PLATFORM" in
    github) echo "${CI_PIPELINE_WORKSPACE:-${RUNNER_TEMP:-/tmp}/pw}" ;;
    ado)    echo "${PIPELINE_WORKSPACE:-$(pwd)}" ;;
    *)      echo "${CI_PIPELINE_WORKSPACE:-$(pwd)}" ;;
  esac
}

# $(System.DefaultWorkingDirectory) — where the triggering repo is checked out.
ci_default_working_directory() {
  case "$CI_PLATFORM" in
    github) echo "${GITHUB_WORKSPACE:-$(pwd)}" ;;
    ado)    echo "${SYSTEM_DEFAULTWORKINGDIRECTORY:-$(pwd)}" ;;
    *)      echo "${CI_DEFAULT_WORKING_DIRECTORY:-$(pwd)}" ;;
  esac
}

ci_workspace() {
  ci_default_working_directory
}

# $(Build.Repository.Name) — short name of the triggering (application) repository.
ci_repo_name() {
  if [[ "$CI_PLATFORM" == "github" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    basename "$GITHUB_REPOSITORY"
  elif [[ -n "${BUILD_REPOSITORY_NAME:-}" ]]; then
    echo "$BUILD_REPOSITORY_NAME"
  else
    echo "${CI_REPO_NAME:-$(basename "$(pwd)")}"
  fi
}

# $(Agent.TempDirectory)
ci_temp_dir() {
  case "$CI_PLATFORM" in
    github) echo "${RUNNER_TEMP:-/tmp}" ;;
    ado)    echo "${AGENT_TEMPDIRECTORY:-/tmp}" ;;
    *)      echo "${TMPDIR:-/tmp}" ;;
  esac
}

# $(Build.ArtifactStagingDirectory)
ci_artifact_staging_dir() {
  case "$CI_PLATFORM" in
    github) echo "${CI_ARTIFACT_STAGING_DIR:-${RUNNER_TEMP:-/tmp}/artifact-staging}" ;;
    ado)    echo "${BUILD_ARTIFACTSTAGINGDIRECTORY:-$(pwd)/artifact-staging}" ;;
    *)      echo "${CI_ARTIFACT_STAGING_DIR:-$(pwd)/artifact-staging}" ;;
  esac
}

# $(Build.BuildNumber)
ci_build_number() {
  case "$CI_PLATFORM" in
    github) echo "${GITHUB_RUN_NUMBER:-0}" ;;
    ado)    echo "${BUILD_BUILDNUMBER:-0}" ;;
    *)      echo "${CI_BUILD_NUMBER:-0}" ;;
  esac
}

# $(Build.SourceBranch) — full ref, e.g. refs/heads/release/1.2 (same shape on both platforms).
ci_source_branch() {
  case "$CI_PLATFORM" in
    github) echo "${GITHUB_REF:-}" ;;
    ado)    echo "${BUILD_SOURCEBRANCH:-}" ;;
    *)      echo "${CI_SOURCE_BRANCH:-}" ;;
  esac
}

# $(Build.SourceVersion)
ci_commit_sha() {
  case "$CI_PLATFORM" in
    github) echo "${GITHUB_SHA:-}" ;;
    ado)    echo "${BUILD_SOURCEVERSION:-}" ;;
    *)      echo "${CI_COMMIT_SHA:-}" ;;
  esac
}
