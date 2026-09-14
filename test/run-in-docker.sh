#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
IMAGE=chronoturtle-test
CONTAINER=${CONTAINER:-chronoturtle-test}

docker build --quiet --tag "$IMAGE" test/db >/dev/null
docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
docker run --detach --name "$CONTAINER" --env POSTGRES_USER=superuser --env POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null
trap 'docker rm --force "$CONTAINER" >/dev/null' EXIT

# TCP, not the socket: the entrypoint's init phase runs a socket-only server that is restarted afterwards.
for _ in $(seq 60); do
    docker exec "$CONTAINER" pg_isready --quiet --host 127.0.0.1 && break
    sleep 1
done

tar -c Makefile chronoturtle.control sql test/sql test/expected \
    | docker exec --interactive "$CONTAINER" bash -c 'mkdir -p /tmp/chronoturtle && tar -x -C /tmp/chronoturtle'

set +e
docker exec --workdir /tmp/chronoturtle --env PGHOST=127.0.0.1 --env PGUSER=superuser "$CONTAINER" \
    bash -c 'rm -f sql/chronoturtle--*.sql && make --silent && make --silent install && make installcheck'
status=$?
set -e

if [ $status -ne 0 ]; then
    docker cp "$CONTAINER:/tmp/chronoturtle/test/regression.diffs" test/ 2>/dev/null && cat test/regression.diffs
fi
exit $status
