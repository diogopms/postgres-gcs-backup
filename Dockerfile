FROM alpine:3.14.0

RUN apk add --update \
  bash \
  postgresql \
  curl \
  python2 \
  python3 \
  py-pip \
  && pip install --upgrade pip \
  && pip install wheel \
  && apk add --virtual build-deps \
  py-cffi \
  gcc \
  libffi-dev \
  python2-dev \
  python3-dev \
  linux-headers \
  musl-dev \
  openssl-dev \
  rust cargo \
  && pip install gsutil \
  && apk del build-deps \
  && rm -rf /var/cache/apk/*

ADD . /postgres-gcs-backup

WORKDIR /postgres-gcs-backup

RUN chmod +x /postgres-gcs-backup/backup.sh

ENTRYPOINT ["/postgres-gcs-backup/backup.sh"]
