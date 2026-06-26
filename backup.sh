#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o errtrace
set -o nounset
# set -o xtrace

JOB_NAME=${JOB_NAME:-default-job}
BACKUP_DIR=${BACKUP_DIR:-/tmp}
BOTO_CONFIG_PATH=${BOTO_CONFIG_PATH:-/root/.boto}
GCS_BUCKET=${GCS_BUCKET:-}
GCS_KEY_FILE_PATH=${GCS_KEY_FILE_PATH:-}
POSTGRES_HOST=${POSTGRES_HOST:-localhost}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_DB=${POSTGRES_DB:-}
POSTGRES_USER=${POSTGRES_USER:-}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
# Extra options passed verbatim to pg_dump (word-split), e.g. "--schema=public --no-owner".
PGDUMP_EXTRA_OPTS=${PGDUMP_EXTRA_OPTS:-}
# When set to a positive integer, backups for this JOB_NAME older than this many
# days are pruned from the bucket after a successful upload.
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-}
SLACK_ALERTS=${SLACK_ALERTS:-}
SLACK_AUTHOR_NAME=${SLACK_AUTHOR_NAME:-postgres-gcs-backup}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
SLACK_CHANNEL=${SLACK_CHANNEL:-}
SLACK_USERNAME=${SLACK_USERNAME:-}
SLACK_ICON=${SLACK_ICON:-}

# Populated by backup(); referenced by the EXIT trap so it must always be defined.
archive_name=""

backup() {
  mkdir -p "$BACKUP_DIR"
  local date
  date=$(date "+%Y-%m-%dT%H:%M:%SZ")
  archive_name="$date-$JOB_NAME-backup.sql.gz"

  # Build the pg_dump arguments as an array so values with spaces are passed
  # safely without eval.
  local -a pg_dump_opts=(
    "--host=$POSTGRES_HOST"
    "--port=$POSTGRES_PORT"
  )
  if [[ -n $POSTGRES_USER ]]; then
    pg_dump_opts+=("--username=$POSTGRES_USER")
  fi
  if [[ -n $POSTGRES_DB ]]; then
    pg_dump_opts+=("--dbname=$POSTGRES_DB")
  fi
  if [[ -n $PGDUMP_EXTRA_OPTS ]]; then
    # Intentional word splitting so callers can pass multiple options.
    # shellcheck disable=SC2206
    pg_dump_opts+=($PGDUMP_EXTRA_OPTS)
  fi

  export PGPASSWORD=$POSTGRES_PASSWORD
  echo "starting to backup PostgreSQL host=$POSTGRES_HOST port=$POSTGRES_PORT db=${POSTGRES_DB:-<all>}"

  pg_dump "${pg_dump_opts[@]}" | gzip > "$BACKUP_DIR/$archive_name"
}

normalize_bucket() {
  if [[ ! "$GCS_BUCKET" =~ ^gs:// ]]; then
    GCS_BUCKET="gs://${GCS_BUCKET}"
  fi
}

write_boto_config() {
  if [[ -n $GCS_KEY_FILE_PATH ]]; then
    cat <<EOF > "$BOTO_CONFIG_PATH"
[Credentials]
gs_service_key_file = $GCS_KEY_FILE_PATH
[Boto]
https_validate_certificates = True
[GoogleCompute]
[GSUtil]
content_language = en
default_api_version = 2
[OAuth2]
EOF
  fi
}

upload_to_gcs() {
  echo "uploading backup archive to GCS bucket=$GCS_BUCKET"
  gsutil cp "$BACKUP_DIR/$archive_name" "$GCS_BUCKET"
}

# Prints an ISO 8601 UTC timestamp for "now minus $1 days".
# Handles GNU coreutils, BSD (macOS) and busybox (alpine) date.
iso_cutoff() {
  local days=$1 now cutoff
  now=$(date -u +%s)
  cutoff=$(( now - days * 86400 ))
  date -u -d "@$cutoff" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null && return 0
  date -u -r "$cutoff" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null && return 0
  return 1
}

# Removes backups for this JOB_NAME older than BACKUP_RETENTION_DAYS from the
# bucket. Runs only after a successful upload and never fails the job: backups
# are named "<ISO timestamp>-<JOB_NAME>-backup.sql.gz", so the timestamp prefix
# can be compared lexicographically against the cutoff.
prune_old_backups() {
  [[ -z $BACKUP_RETENTION_DAYS ]] && return 0
  if ! [[ $BACKUP_RETENTION_DAYS =~ ^[0-9]+$ ]]; then
    echo "ignoring invalid BACKUP_RETENTION_DAYS='$BACKUP_RETENTION_DAYS' (expected a positive integer)" >&2
    return 0
  fi

  local cutoff
  if ! cutoff=$(iso_cutoff "$BACKUP_RETENTION_DAYS"); then
    echo "could not compute retention cutoff; skipping prune" >&2
    return 0
  fi
  echo "pruning backups for job=$JOB_NAME older than $cutoff ($BACKUP_RETENTION_DAYS days)"

  local obj base ts
  while read -r obj; do
    [[ -z $obj ]] && continue
    base=${obj##*/}
    [[ $base == *-"$JOB_NAME"-backup.sql.gz ]] || continue
    ts=${base%%-"$JOB_NAME"-backup.sql.gz}
    if [[ $ts < $cutoff ]]; then
      echo "deleting old backup $obj"
      gsutil rm "$obj" || true
    fi
  done < <(gsutil ls "$GCS_BUCKET/" 2>/dev/null || true)
}

send_slack_message() {
  local color=${1}
  local title=${2}
  local message=${3}

  echo "Sending to ${SLACK_CHANNEL}..."
  curl --data-urlencode \
    "$(printf 'payload={"channel": "%s", "username": "%s", "link_names": "true", "icon_url": "%s", "attachments": [{"author_name": "%s", "title": "%s", "text": "%s", "color": "%s"}]}' \
        "${SLACK_CHANNEL}" \
        "${SLACK_USERNAME}" \
        "${SLACK_ICON}" \
        "${SLACK_AUTHOR_NAME}" \
        "${title}" \
        "${message}" \
        "${color}" \
    )" \
    "${SLACK_WEBHOOK_URL}" || true
  echo
}

err() {
  err_msg="${JOB_NAME} Something went wrong on line $(caller)"
  echo "$err_msg" >&2
  if [[ $SLACK_ALERTS == "true" ]]; then
    send_slack_message "danger" "Error while performing postgres backup" "$err_msg"
  fi
}

cleanup() {
  if [[ -n $archive_name ]]; then
    rm -f "$BACKUP_DIR/$archive_name"
  fi
}

main() {
  if [[ -z $GCS_BUCKET ]]; then
    echo "GCS_BUCKET is required" >&2
    exit 1
  fi

  trap err ERR
  trap cleanup EXIT

  normalize_bucket
  write_boto_config
  backup
  upload_to_gcs
  prune_old_backups
  echo "backup done!"
}

# Only run the backup flow when executed directly; sourcing the script (e.g. in
# tests) just loads the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
