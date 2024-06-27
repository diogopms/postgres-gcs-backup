#!/bin/bash

JOB_NAME=${JOB_NAME:-default-job}
BACKUP_DIR=${BACKUP_DIR:-/tmp}
GCS_BUCKET=${GCS_BUCKET:-}
GCS_KEY_FILE_PATH=${GCS_KEY_FILE_PATH:-/secrets/gcp/gcs-creds.json}
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

backup() {
  mkdir -p $BACKUP_DIR
  date=$(date "+%Y-%m-%dT%H:%M:%SZ")
  archive_name="$date-$JOB_NAME-backup.sql.gz"
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
  cmd="pg_dump --host=\"$POSTGRES_HOST\" --port=\"$POSTGRES_PORT\" $cmd_auth_part $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
  echo "starting to backup PostGRES host=$POSTGRES_HOST port=$POSTGRES_PORT"

  eval "$cmd"
}

upload_to_gcs() {
  if [[ ! "$GCS_BUCKET" =~ gs://* ]]; then
    GCS_BUCKET="gs://${GCS_BUCKET}"
  fi

  echo "Activating service account"
  gcloud auth activate-service-account --key-file=$GCS_KEY_FILE_PATH 
  echo "Uploading backup $archive_name to gcs"
  gsutil cp $BACKUP_DIR/$archive_name $GCS_BUCKET/kratos/$archive_name 2>&1
  echo "Uploaded backup successfully"
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
