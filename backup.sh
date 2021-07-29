#!/bin/bash
set -o pipefail
set -o errexit
# set -o errtrace
set -o nounset
# set -o xtrace

JOB_NAME=${JOB_NAME:-default-job}
BACKUP_DIR=${BACKUP_DIR:-/tmp}
BOTO_CONFIG_PATH=${BOTO_CONFIG_PATH:-/root/.boto}
GCS_BUCKET=${GCS_BUCKET:-}
GCS_BUCKET_PATH_PREFIX=${GCS_BUCKET_PATH_PREFIX:-}
GCS_BUCKET_PATH_DATE_PREFIX=${GCS_BUCKET_PATH_DATE_PREFIX:-}
GCS_KEY_FILE_PATH=${GCS_KEY_FILE_PATH:-}
POSTGRES_HOST=${POSTGRES_HOST:-localhost}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_DB=${POSTGRES_DB:-}
POSTGRES_USER=${POSTGRES_USER:-}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
SLACK_ALERTS=${SLACK_ALERTS:-}
SLACK_AUTHOR_NAME=${SLACK_AUTHOR_NAME:-postgres-gcs-backup}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
SLACK_CHANNEL=${SLACK_CHANNEL:-}
SLACK_USERNAME=${SLACK_USERNAME:-}
SLACK_ICON=${SLACK_ICON:-}
DATE_FORMAT=${DATE_FORMAT:-"%Y-%m-%dT%H:%M:%SZ"}

backup() {
  mkdir -p $BACKUP_DIR
  date=$(date "+$DATE_FORMAT")
  cmd_auth_part=""
  if [[ ! -z $POSTGRES_USER ]] && [[ ! -z $POSTGRES_PASSWORD ]]
  then
    cmd_auth_part="--username=\"$POSTGRES_USER\" "
  fi

  cmd_db_part=""
  if [[ ! -z $POSTGRES_DB ]]
  then
    cmd_db_part="--db=\"$POSTGRES_DB\""
  fi

  export PGPASSWORD=$POSTGRES_PASSWORD

  if [[ ! -z $POSTGRES_DB ]]; then
    archive_name="$date-$POSTGRES_DB-backup.sql.gz"
    cmd="pg_dump --host=\"$POSTGRES_HOST\" --port=\"$POSTGRES_PORT\" $cmd_auth_part $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
  else
    archive_name="$date-alldatabases-backup.sql.gz"
    echo "Dumping all databases"
    cmd="pg_dumpall --host=\"$POSTGRES_HOST\" --port=\"$POSTGRES_PORT\" $cmd_auth_part $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
  fi

  echo "starting to backup PostGRES host=$POSTGRES_HOST port=$POSTGRES_PORT"
  echo "$cmd"
  eval "$cmd"
}

upload_to_gcs() {
  if [[ ! "$GCS_BUCKET" =~ gs://* ]]; then
    GCS_BUCKET="gs://${GCS_BUCKET}"
  fi

  if [[ ! -z "$GCS_BUCKET_PATH_PREFIX" ]]; then
      GCS_BUCKET=$GCS_BUCKET$GCS_BUCKET_PATH_PREFIX
  fi

  if [[ "$GCS_BUCKET_PATH_DATE_PREFIX" == "true" ]]; then
      GCS_BUCKET=$GCS_BUCKET$(date "+%Y")/$(date "+%m")/$(date "+%d")/
  fi

  if [[ $GCS_KEY_FILE_PATH != "" ]]
  then
cat <<EOF > $BOTO_CONFIG_PATH
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
  echo "uploading backup archive to GCS bucket=$GCS_BUCKET"
  gsutil cp $BACKUP_DIR/$archive_name $GCS_BUCKET
}

send_slack_message() {
  local color=${1}
  local title=${2}
  local message=${3}

  echo 'Sending to '${SLACK_CHANNEL}'...'
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
    ${SLACK_WEBHOOK_URL} || true
  echo
}

err() {
  err_msg="${JOB_NAME} Something went wrong on line $(caller)"
  echo $err_msg >&2
  if [[ $SLACK_ALERTS == "true" ]]
  then
    send_slack_message "danger" "Error while performing postgres backup" "$err_msg"
  fi
}

cleanup() {
  rm $BACKUP_DIR/$archive_name
}

trap err ERR
backup
upload_to_gcs
cleanup
echo "backup done!"
