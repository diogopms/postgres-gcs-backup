FROM python:alpine3.20

RUN apk add --update \
  bash \
  postgresql16 \
  curl \
  && pip install gsutil \
  && rm -rf /var/cache/apk/*

ADD . /postgres-gcs-backup

WORKDIR /postgres-gcs-backup

RUN chmod +x /postgres-gcs-backup/backup.sh

ENTRYPOINT ["/postgres-gcs-backup/backup.sh"]
