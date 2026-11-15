#!/usr/bin/env bash
#
# Shared Cloudflare R2 client tuning and transient-failure retries for the
# object-storage publishers.
#
# Source this file from a publisher; it is not meant to be executed directly.
#
# Only transient failures are retried. Every request the publishers send is
# idempotent (PUT/COPY/HEAD/DELETE against a fixed key) or a whole-object
# transfer that restarts from the beginning, so repeating an attempt cannot
# duplicate, reorder or partially promote published state. Authentication,
# authorization and bucket-configuration errors are never retried, so a real
# credential or policy regression still fails immediately instead of being
# hidden behind retries.

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  printf '[aws-r2-retry] ERROR: source this file, do not execute it\n' >&2
  exit 1
fi

# Attempts for mutating requests (uploads, copies, deletes).
R2_RETRY_MAX_ATTEMPTS="${R2_RETRY_MAX_ATTEMPTS:-4}"
# Delays double per attempt, capped, then jittered down by up to half.
R2_RETRY_BASE_DELAY_SECONDS="${R2_RETRY_BASE_DELAY_SECONDS:-5}"
R2_RETRY_MAX_DELAY_SECONDS="${R2_RETRY_MAX_DELAY_SECONDS:-60}"
# Verification reads are cheap and non-destructive; keep their retries short.
R2_VERIFY_ATTEMPTS="${R2_VERIFY_ATTEMPTS:-3}"
# Verification over the public endpoint tolerates slow CDN edges.
R2_VERIFY_CURL_RETRIES="${R2_VERIFY_CURL_RETRIES:-3}"
R2_VERIFY_CURL_RETRY_DELAY_SECONDS="${R2_VERIFY_CURL_RETRY_DELAY_SECONDS:-2}"

# Errors where a repeat attempt is safe and likely to succeed.
aws_r2_retryable_patterns=(
  'InvalidPart(Order)?'
  'IncompleteBody'
  'RequestTimeout'
  'RequestTimeTooSkewed'
  'OperationAborted'
  'SlowDown'
  'Throttl'
  'InternalError'
  'ServiceUnavailable'
  'Connection reset'
  'Connection aborted'
  'Connection refused'
  'Broken pipe'
  '[Tt]imed out'
  'TLS handshake'
  'EOF occurred'
  'Could not connect'
  'NetworkingError'
  'An error occurred \(50[0-9]\)'
  'An error occurred \(429\)'
)

# Errors where a repeat attempt is pointless or dangerous, so fail fast.
aws_r2_fatal_patterns=(
  'AccessDenied'
  'AllAccessDisabled'
  'AuthorizationHeaderMalformed'
  'EntityTooLarge'
  'Forbidden'
  'InvalidAccessKeyId'
  'InvalidBucketName'
  'InvalidPart number'
  'NoSuchBucket'
  'NoSuchKey'
  'SignatureDoesNotMatch'
  '\((400|401|403|404)\)'
)

aws_r2_log() {
  printf '[aws-r2-retry] %s\n' "$*" >&2
}

# Install an AWS CLI client configuration that suits large object uploads to
# R2: fewer, larger multipart parts and lower request concurrency reduce the
# chance of a part disappearing before CompleteMultipartUpload. Callers that
# already point AWS_CONFIG_FILE somewhere else keep their own configuration.
aws_r2_configure_client() {
  local config_dir
  local config_path

  if [[ "${R2_CLIENT_CONFIGURED:-}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${AWS_CONFIG_FILE:-}" ]]; then
    aws_r2_log "Using caller-provided AWS_CONFIG_FILE: ${AWS_CONFIG_FILE}"
    export R2_CLIENT_CONFIGURED=1
    return 0
  fi

  config_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/veldmuis/aws"
  config_path="${config_dir}/r2-client.conf"
  mkdir -p "${config_dir}"

  (
    umask 077
    cat > "${config_path}" <<'EOF'
[default]
retry_mode = standard
max_attempts = 5

s3 =
  multipart_threshold = 64MB
  multipart_chunksize = 64MB
  max_concurrent_requests = 4
EOF
  )

  export AWS_CONFIG_FILE="${config_path}"
  export R2_CLIENT_CONFIGURED=1
  aws_r2_log "Configured AWS CLI for R2 transfers: ${config_path}"
}

aws_r2_failure_is_retryable() {
  local failure_log="$1"
  local pattern

  for pattern in "${aws_r2_fatal_patterns[@]}"; do
    if grep -Eq -- "${pattern}" "${failure_log}"; then
      return 1
    fi
  done

  for pattern in "${aws_r2_retryable_patterns[@]}"; do
    if grep -Eq -- "${pattern}" "${failure_log}"; then
      return 0
    fi
  done

  return 1
}

aws_r2_backoff_delay() {
  local attempt="$1"
  local delay
  local jitter_window

  delay=$(( R2_RETRY_BASE_DELAY_SECONDS * (1 << (attempt - 1)) ))
  if (( delay > R2_RETRY_MAX_DELAY_SECONDS )); then
    delay="${R2_RETRY_MAX_DELAY_SECONDS}"
  fi

  jitter_window=$(( delay / 2 ))
  if (( jitter_window > 0 )); then
    delay=$(( jitter_window + RANDOM % (jitter_window + 1) ))
  fi

  printf '%s' "${delay}"
}

# aws_r2 [--attempts N] [--label TEXT] -- <aws arguments...>
#
# Runs the AWS CLI, echoing its stderr after each failed attempt, and retries
# only when the failure looks transient. Returns the AWS CLI exit status.
aws_r2() {
  local attempts="${R2_RETRY_MAX_ATTEMPTS}"
  local label=""
  local attempt=1
  local exit_code=0
  local delay
  local failure_log

  while (( $# > 0 )); do
    case "$1" in
      --attempts)
        [[ $# -ge 2 ]] || { aws_r2_log "--attempts requires a value"; return 2; }
        attempts="$2"
        shift 2
        ;;
      --label)
        [[ $# -ge 2 ]] || { aws_r2_log "--label requires a value"; return 2; }
        label="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ ! "${attempts}" =~ ^[0-9]+$ ]] || (( attempts < 1 )); then
    aws_r2_log "Invalid attempt count: ${attempts}"
    return 2
  fi

  if [[ -z "${label}" ]]; then
    label="aws ${1:-request} ${2:-}"
  fi

  failure_log="$(mktemp "${TMPDIR:-/tmp}/veldmuis-aws-r2.XXXXXX")"

  while :; do
    exit_code=0
    if aws "$@" 2>"${failure_log}"; then
      if [[ -s "${failure_log}" ]]; then
        cat "${failure_log}" >&2
      fi
      rm -f -- "${failure_log}"
      return 0
    else
      exit_code=$?
    fi

    if [[ -s "${failure_log}" ]]; then
      cat "${failure_log}" >&2
    fi

    if (( attempt >= attempts )); then
      aws_r2_log "${label} failed after ${attempt} attempt(s)"
      rm -f -- "${failure_log}"
      return "${exit_code}"
    fi

    if ! aws_r2_failure_is_retryable "${failure_log}"; then
      aws_r2_log "${label} failed with a non-retryable error; not retrying"
      rm -f -- "${failure_log}"
      return "${exit_code}"
    fi

    delay="$(aws_r2_backoff_delay "${attempt}")"
    aws_r2_log "${label} failed (attempt ${attempt}/${attempts}, exit ${exit_code}); retrying in ${delay}s"
    attempt=$(( attempt + 1 ))
    sleep "${delay}"
    : > "${failure_log}"
  done
}
