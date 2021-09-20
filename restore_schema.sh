#!/bin/bash

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
  SRC=$2
else
      echo "No schema file specified. $USAGE"
      exit 98
fi

if [ -n "$3" ];then
  DB=$3
else
  echo "No dbname specified. $USAGE"
fi

# параметры подключения к серверу (не тестировалось для удаленных машин / с auth)
DB_HOST="${CONN_HOST:+--host=}${CONN_HOST}"
DB_PORT="${CONN_PORT:+--port=}${CONN_PORT}"
DB_USER="${CONN_USER:+--no-password --username=}${CONN_USER}"

OPTIONS="$DB_HOST $DB_PORT $DB_USER"
PSQL="psql $OPTIONS"

if [ -n "$DB_USER" ];then
        echo "*:*:*:${CONN_USER}:${CONN_PASS}" > ~/.pgpass
        chmod 600 ~/.pgpass
fi

echo $PSQL;
$PSQL $DB < $SRC

[ -f ~/.pgpass ] && rm ~/.pgpass