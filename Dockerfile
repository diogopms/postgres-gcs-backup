FROM gcr.io/google.com/cloudsdktool/cloud-sdk:alpine

RUN apk add --update postgresql-client
RUN apk add --update bash
RUN apk add --update curl

ADD . /postgres-gcs-backup

WORKDIR /postgres-gcs-backup

RUN chmod +x /postgres-gcs-backup/backup.sh

ENTRYPOINT ["/postgres-gcs-backup/backup.sh"]
