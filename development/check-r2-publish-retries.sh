#!/usr/bin/env bash
#
# Exercises the R2 retry helper used by the object-storage publishers. Every
# case drives a fake AWS CLI so the retry policy is verified without touching
# Cloudflare R2.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_root="$(mktemp -d -t veldmuis-r2-retry-check.XXXXXX)"
fake_bin="${temp_root}/bin"
fake_counter="${temp_root}/aws-counter"
fake_log="${temp_root}/aws.log"

cleanup() {
  [[ -n "${temp_root}" && "${temp_root}" == /tmp/veldmuis-r2-retry-check.* ]] || return 0
  rm -rf -- "${temp_root}"
}
trap cleanup EXIT

log() {
  printf '[check-r2-publish-retries] %s\n' "$*"
}

fail() {
  printf '[check-r2-publish-retries] ERROR: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${fake_bin}"
cat > "${fake_bin}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [[ -f "${FAKE_AWS_COUNTER}" ]]; then
  count="$(cat "${FAKE_AWS_COUNTER}")"
fi
count=$((count + 1))
printf '%s' "${count}" >"${FAKE_AWS_COUNTER}"
printf '%s\n' "$*" >>"${FAKE_AWS_LOG}"

if ((count <= ${FAKE_AWS_FAIL_TIMES:-0})); then
  if [[ -n "${FAKE_AWS_STDERR:-}" ]]; then
    printf '%s\n' "${FAKE_AWS_STDERR}" >&2
  fi
  exit "${FAKE_AWS_EXIT:-1}"
fi

printf '%s' "${FAKE_AWS_STDOUT:-}"
EOF
chmod +x "${fake_bin}/aws"

export PATH="${fake_bin}:${PATH}"
export FAKE_AWS_COUNTER="${fake_counter}"
export FAKE_AWS_LOG="${fake_log}"
export R2_RETRY_BASE_DELAY_SECONDS=0
export R2_RETRY_MAX_DELAY_SECONDS=0

# shellcheck source=development/aws-r2-retry.sh
. "${script_dir}/aws-r2-retry.sh"

reset_fake() {
  : >"${fake_log}"
  rm -f -- "${fake_counter}"
  unset FAKE_AWS_FAIL_TIMES FAKE_AWS_EXIT FAKE_AWS_STDERR FAKE_AWS_STDOUT
}

attempts_used() {
  [[ -f "${fake_counter}" ]] || { printf '0'; return 0; }
  cat "${fake_counter}"
}

check_transient_failure_is_retried() {
  local output=""
  local error_log="${temp_root}/transient.err"

  reset_fake
  export FAKE_AWS_FAIL_TIMES=2
  export FAKE_AWS_EXIT=1
  export FAKE_AWS_STDERR='An error occurred (InvalidPart) when calling the CompleteMultipartUpload operation: One or more of the specified parts could not be found.'
  export FAKE_AWS_STDOUT='recovered'

  output="$(aws_r2 --attempts 4 --label "multipart upload" -- s3 cp payload target 2>"${error_log}")" \
    || fail "transient failure was not retried to success"

  [[ "${output}" == "recovered" ]] || fail "successful attempt stdout was not preserved"
  [[ "$(attempts_used)" == "3" ]] || fail "expected 3 attempts, saw $(attempts_used)"
  grep -qF "retrying in 0s" "${error_log}" || fail "retry attempt was not logged"
  grep -qF "InvalidPart" "${error_log}" || fail "AWS CLI error output was not surfaced"
  log "Retries transient InvalidPart failures and preserves output"
}

check_permission_error_fails_fast() {
  local exit_code=0

  reset_fake
  export FAKE_AWS_FAIL_TIMES=1
  export FAKE_AWS_EXIT=1
  export FAKE_AWS_STDERR='An error occurred (AccessDenied) when calling the PutObject operation: Access Denied'

  exit_code=0
  aws_r2 --attempts 4 --label "upload" -- s3 cp payload target 2>"${temp_root}/denied.err" \
    || exit_code=$?

  ((exit_code != 0)) || fail "permission failure was reported as success"
  [[ "$(attempts_used)" == "1" ]] || fail "permission failure was retried $(attempts_used) times"
  grep -qF "non-retryable" "${temp_root}/denied.err" \
    || fail "permission failure was not classified as non-retryable"
  log "Fails fast without retrying authorization errors"
}

check_unknown_error_fails_fast() {
  local exit_code=0

  reset_fake
  export FAKE_AWS_FAIL_TIMES=1
  export FAKE_AWS_EXIT=1
  export FAKE_AWS_STDERR='Something unclassified went wrong'

  exit_code=0
  aws_r2 --attempts 4 --label "upload" -- s3 cp payload target 2>/dev/null || exit_code=$?

  ((exit_code != 0)) || fail "unclassified failure was reported as success"
  [[ "$(attempts_used)" == "1" ]] || fail "unclassified failure was retried $(attempts_used) times"
  log "Treats unclassified errors as non-retryable"
}

check_retries_are_bounded() {
  local exit_code=0

  reset_fake
  export FAKE_AWS_FAIL_TIMES=99
  export FAKE_AWS_EXIT=1
  export FAKE_AWS_STDERR='An error occurred (SlowDown) when calling the PutObject operation: Please reduce your request rate.'

  exit_code=0
  aws_r2 --attempts 2 --label "upload" -- s3 cp payload target 2>"${temp_root}/bounded.err" \
    || exit_code=$?

  ((exit_code != 0)) || fail "exhausted retries were reported as success"
  [[ "$(attempts_used)" == "2" ]] || fail "attempt limit ignored: $(attempts_used) attempts"
  grep -qF "failed after 2 attempt(s)" "${temp_root}/bounded.err" \
    || fail "attempt exhaustion was not reported"
  log "Stops after the configured attempt limit"
}

check_exit_code_is_propagated() {
  local exit_code=0

  reset_fake
  export FAKE_AWS_FAIL_TIMES=1
  export FAKE_AWS_EXIT=42
  export FAKE_AWS_STDERR='An error occurred (NoSuchBucket) when calling the HeadObject operation'

  exit_code=0
  aws_r2 --attempts 3 --label "verify" -- s3api head-object 2>/dev/null || exit_code=$?

  [[ "${exit_code}" == "42" ]] || fail "expected exit 42, saw ${exit_code}"
  log "Propagates the AWS CLI exit status"
}

check_backoff_grows_and_caps() {
  local attempt
  local delay
  local lower
  local upper

  for attempt in 1 2 3; do
    delay="$(R2_RETRY_BASE_DELAY_SECONDS=4 R2_RETRY_MAX_DELAY_SECONDS=10 aws_r2_backoff_delay "${attempt}")"
    case "${attempt}" in
      1) lower=2; upper=4 ;;
      2) lower=4; upper=8 ;;
      *) lower=5; upper=10 ;;
    esac
    ((delay >= lower && delay <= upper)) \
      || fail "attempt ${attempt} delay ${delay}s outside ${lower}-${upper}s"
  done

  delay="$(R2_RETRY_BASE_DELAY_SECONDS=0 R2_RETRY_MAX_DELAY_SECONDS=10 aws_r2_backoff_delay 5)"
  [[ "${delay}" == "0" ]] || fail "zero base delay did not disable waiting"
  log "Backoff grows per attempt, stays capped, and supports a zero base delay"
}

check_client_configuration() {
  local config_path=""

  unset AWS_CONFIG_FILE
  unset R2_CLIENT_CONFIGURED
  export XDG_CACHE_HOME="${temp_root}/cache"

  aws_r2_configure_client 2>/dev/null
  config_path="${AWS_CONFIG_FILE}"
  [[ -f "${config_path}" ]] || fail "client configuration was not written"
  grep -qF "multipart_chunksize = 64MB" "${config_path}" \
    || fail "client configuration does not size multipart parts"
  grep -qF "multipart_threshold = 64MB" "${config_path}" \
    || fail "client configuration does not set the multipart threshold"
  grep -qF "max_concurrent_requests = 4" "${config_path}" \
    || fail "client configuration does not limit request concurrency"
  grep -qF "max_attempts = 5" "${config_path}" \
    || fail "client configuration does not raise request retries"

  aws_r2_configure_client >/dev/null 2>&1
  [[ "${AWS_CONFIG_FILE}" == "${config_path}" ]] || fail "client configuration was not idempotent"

  export AWS_CONFIG_FILE="${temp_root}/caller.conf"
  printf '[default]\nregion = auto\n' >"${AWS_CONFIG_FILE}"
  unset R2_CLIENT_CONFIGURED
  aws_r2_configure_client >/dev/null 2>&1
  [[ "${AWS_CONFIG_FILE}" == "${temp_root}/caller.conf" ]] \
    || fail "caller-provided AWS_CONFIG_FILE was overwritten"
  unset AWS_CONFIG_FILE
  unset R2_CLIENT_CONFIGURED
  log "Tunes multipart transfers, retries, and concurrency without clobbering callers"
}

check_publishers_use_shared_retry() {
  local publisher

  for publisher in \
    publish-r2-package-repo.sh \
    publish-r2-release.sh \
    publish-known-good-nvidia-packages.sh \
    prune-release-storage.sh
  do
    grep -qF 'aws-r2-retry.sh' "${script_dir}/${publisher}" \
      || fail "${publisher} does not source the shared R2 retry helper"
    bash -n "${script_dir}/${publisher}"
  done
  log "All R2 publishers source the shared retry helper"
}

check_transient_failure_is_retried
check_permission_error_fails_fast
check_unknown_error_fails_fast
check_retries_are_bounded
check_exit_code_is_propagated
check_backoff_grows_and_caps
check_client_configuration
check_publishers_use_shared_retry

printf '[check-r2-publish-retries] R2 publishers retry only transient failures and fail fast on the rest.\n'
