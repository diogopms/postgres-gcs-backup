FROM python:3.12-slim

# Install PostgreSQL 17 client from official PostgreSQL repository
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  curl \
  gnupg \
  lsb-release \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
  postgresql-client-17 \
  && pip install gsutil \
  && apt-get purge -y --auto-remove \
  gnupg \
  lsb-release \
  && rm -rf /var/lib/apt/lists/*

ADD . /postgres-gcs-backup

WORKDIR /postgres-gcs-backup

RUN chmod +x /postgres-gcs-backup/backup.sh

ENTRYPOINT ["/postgres-gcs-backup/backup.sh"]
