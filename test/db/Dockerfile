FROM postgres:16.6

RUN apt-get update && apt-get -y install curl gnupg apt-transport-https

RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/postgres_archive.gpg && \
    echo deb [ signed-by=/etc/apt/trusted.gpg.d/postgres_archive.gpg ] https://apt-archive.postgresql.org/pub/repos/apt bookworm-pgdg-archive main > /etc/apt/sources.list.d/pgdg_archive.list

RUN apt-get update && \
    apt-get install -y make postgresql-server-dev-16 \
    postgresql-16-postgis-3=3.3.4+dfsg-1.pgdg120+1 \
    postgresql-16-postgis-3-scripts=3.3.4+dfsg-1.pgdg120+1 \
    postgresql-16-repack

RUN rm -rf /var/lib/apt/lists/* && \
    localedef -i de_CH -c -f UTF-8 -A /usr/share/locale/locale.alias de_CH.UTF-8
ENV LANG de_CH.UTF-8
