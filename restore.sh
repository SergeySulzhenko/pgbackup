#!/bin/bash

set -xe
exec 2>&1
CONFIG=$1

USAGE="Usage: $0 /path/to/.env /path/to/schema.sql dbname"

if [ -f "$CONFIG" ];then
    source $CONFIG
else
    echo "No config file specified. $USAGE"
    exit 99
fi


if [ -n "$2" -a -f "$1" ];then
  SRC=$(readlink -f $2)
else
      echo "No data/tar file specified. $USAGE"
      exit 98
fi

if [ -n "$3" ];then
  DB=$3
else
  echo "No dbname specified. $USAGE"
fi

DD=$DUMP_DIR

if [ ! -d "$DD" ]; then
    stdlog "Work directory not found: $1"
    exit 1
fi

set -x

# параметры подключения к серверу (не тестировалось для удаленных машин / с auth)
DB_HOST="${CONN_HOST:+--host=}${CONN_HOST}"
DB_PORT="${CONN_PORT:+--port=}${CONN_PORT}"
DB_USER="${CONN_USER:+--no-password --username=}${CONN_USER}"
DB_JOBS="${DUMP_JOBS:+--jobs=}${DUMP_JOBS}"

OPTIONS="$DB_HOST $DB_PORT $DB_USER"
RESTORE="pg_restore $OPTIONS -a --disable-triggers"

if [ -n "$DB_USER" ];then
        echo "*:*:*:${CONN_USER}:${CONN_PASS}" > ~/.pgpass
        chmod 600 ~/.pgpass
fi

cd $DD &&
  tar xf $SRC &&
  find . -type f -exec mv -i {} . \; &&
  $RESTORE -d $DB ./ &&
  rm ./*.dat*

[ -f ~/.pgpass ] && rm ~/.pgpass