#!/bin/bash

# @homepage - https://github.com:SergeySulzhenko/pgbackup

# Скрипт для архивирования баз postgres
# Запуск: backup.sh .env
# где .env - файл с конфигурацией, в нём должны быть объявлены переменные:
#
# DATABASES="db1 db2" - список баз для архивации, через пробел
# DUMP_DIR="/var/backup/pgsql" - временный каталог для записи нового дампа
# STORE_DIR="/var/backup/nfs_share" - каталог для хранения дампов
# STORE_DIR_MOUNT="1" - признак необходимости монтирования, если не пустое
# CONN_HOST="/var/run/postgresql" - хост/unix-socket для подключения
# CONN_PORT="5432" - порт подключения
#
#
# Необязательные параметры конфигурации
# DUMP_PREFIX="" - каталог где размещены pg_dump & pg_dumpall (на случай если в системе установлено больше одной версии postgresql)
# DUMP_JOBS=8 - параллельные потоки, установить по числу ядер, либо меньше
# DUMP_OPTS="--compress=9" - прочие опции для pg_dump
# CONN_USER="root" - user/password для подключения (если запускается не из под postgres. не тестировалось!!)
# CONN_PASS="root"
# TTL_DAYS_DAILY=8  - время хранения архивов для daily|weekly|monthly
# TTL_DAYS_WEEKLY=35
# TTL_DAYS_MONTHLY=180
#
#+++++++++++++++++++++++++++++++++++++++++++++++
# Сценарий архивирует в отдельные файлы роли и схему.
# После этого для каждой базы создает дамп в формате Directory, упаковывает его в tar.
# Если текущая дата соответствует понедельнику или 1 числу месяца - создаются hard-ссылки в подкаталогах weekly и monthly соответственно
#
# По истечении времени хранения файлов они удалятся. Время хранения описано в TTL_DAYS_*
#

exec 2>&1
CONFIG=$1

if [ -f "$CONFIG" ];then
    source $CONFIG
else
    echo No config file specified. Usage: $0 /path/to/config
    exit 99
fi

# префикс для файлов
DATE="`date +%m%d`"

# временная директория для выгрузки дампа
DD=$DUMP_DIR

# директории для хранения
SD=$STORE_DIR
SD_DAILY="${SD}/daily"
SD_WEEKLY="${SD}/weekly"
SD_MONTHLY="${SD}/monthly"
SM=$STORE_DIR_MOUNT

# время хранения копий
TTL_DAYS_DAILY=${TTL_DAYS_DAILY:-8} #храним 8 дней
TTL_DAYS_WEEKLY=${TTL_DAYS_WEEKLY:-35} #храним 5 недель
TTL_DAYS_MONTHLY=${TTL_DAYS_MONTHLY:-180} #храним 6 месяцев

# дни создания weekly|monthly копий
SAVE_DOW=${SAVE_DOW:-"1"} # Day Of Week
SAVE_DOM=${SAVE_DOM:-"01"} # Day Of Month

# параметры подключения к серверу (не тестировалось для удаленных машин / с auth)
DB_HOST="${CONN_HOST:+--host=}${CONN_HOST}"
DB_PORT="${CONN_PORT:+--port=}${CONN_PORT}"
DB_USER="${CONN_USER:+--no-password --username=}${CONN_USER}"
DB_JOBS="${DUMP_JOBS:+--jobs=}${DUMP_JOBS}"

# опции и команды pg_dump(all)
OPTIONS="$DB_HOST $DB_PORT $DB_USER $DB_JOBS $DUMP_OPTS"
DUMP="${DUMP_PREFIX}pg_dump $OPTIONS"
DUMP_ALL="${DUMP_PREFIX}pg_dumpall $DB_HOST $DB_PORT $DB_USER"


stdlog()
{
    echo `date +%H:%M:%S` $1
}

check_dir()
{
    if [ ! -d "$1" ]; then
        stdlog "Work directory not found: $1"
        exit 1
    fi
}

check_reqs()
{
    if [ ! -z "$SM" ]; then
      mount | grep `dirname $SD` > /dev/null
      if [ "$?" != "0" ]; then
          mount `dirname $SD`
      fi
    fi
    check_dir $SD


    check_dir $DD

    [ -d "$SD_DAILY" ] || mkdir -p $SD_DAILY
    check_dir $SD_DAILY

    [ -d "$SD_WEEKLY" ] || mkdir -p $SD_WEEKLY
    check_dir $SD_WEEKLY

    [ -d "$SD_MONTHLY" ] || mkdir -p $SD_MONTHLY
    check_dir $SD_MONTHLY

    ${DUMP_PREFIX}pg_dump --help > /dev/null
    if [ "$?" != "0" ];then
        stdlog "Dump command not found: $DUMP"
    fi

    if [ ! -z "$DB_USER" ];then
        echo "*:*:*:${CONN_USER}:${CONN_PASS}" > ~/.pgpass
        chmod 600 ~/.pgpass
    fi

}

post_clean()
{
    stdlog "Start post cleaning"
    [ -f ~/.pgpass ] && rm ~/.pgpass

    find $SD_DAILY -type f -mtime +"${TTL_DAYS_DAILY}" -delete
    find $SD_WEEKLY -type f -mtime +"${TTL_DAYS_WEEKLY}" -delete
    find $SD_MONTHLY -type f -mtime +"${TTL_DAYS_MONTHLY}" -delete

    stdlog ".. completed"
}

dump_roles()
{
    # DST=/var/backup/psqlbackup/daily/yymmdd_roles.sql
    DST=$1
    stdlog "Dumping roles to $DST"

    $DUMP_ALL --roles-only -f $DST

    if [ "$?" = "0" ];then
        stdlog "..completed"
    else
        stdlog "!!! error"
    fi

    return $?
}

dump_schema()
{
    # DST=/var/backup/psqlbackup/daily/yymmdd_schema.sql
    DST=$1
    stdlog "Dumping schema to $DST"
    $DUMP_ALL --schema-only -f $DST

    if [ "$?" = "0" ];then
        stdlog "..completed"
    else
        stdlog "!!! error"
    fi

    return $?
}

dump_data()
{
    # DST=/var/backup/psqlbackup/daily
    DST="$1"

    stdlog "Start dump data"

    for DB in `echo $DATABASES`; do
        stdlog "..dumping $DB to $DST"

        # pg_dump ... /var/backup/psqlbackup/daily/yymmdd_depo depo
        if [ -d "${DD}/${DB}" ];then
            stdlog "..found old directory, removing ${DD}/${DB}..."
            rm -rf "${DD}/${DB}"
        fi

        cd "${DST}" &&
        $DUMP -f "./${DATE}_${DB}_schema.sql" --schema-only $DB &&
        $DUMP -Fd -f "${DD}/${DB}" $DB \
            && stdlog "Dump ready. Start packing to tar" \
            && tar cf "./${DATE}_${DB}.tar" "${DD}/${DB}" \
            && stdlog "Tar ready. Removing dump directory" \
            && rm -rf "${DD}/${DB}"

        if [ "$?" = "0" ];then
            stdlog "  ..completed: $DB"
        else
            stdlog "!!! error on: $DB"
            return $?
        fi
    done

    stdlog ".. completed"
    return 0
}

dump_all()
{
    # TRG=/var/backup/psqlbackup/daily
    TRG=$1

    dump_config ${CONFIG_DIR:-/etc/postgresql} "${TRG}" \
        && dump_roles "${TRG}/${DATE}_roles.sql" \
        && dump_schema "${TRG}/${DATE}_schema.sql" \
        && dump_data "${TRG}"

    return $?
}

dump_config()
{
    # SRC=/etc/postgresql
    # TRG=/var/backup/psqlbackup/daily
    SRC=$1
    TRG=$2
    if [ -n "$SRC" -a -d "$SRC" ]; then
      tar czpf "${TRG}/${DATE}_config.tgz" /etc/postgresql
    fi

    return $?
}

create_links()
{
    # DST=/var/backup/psqlbackup/daily
    DST=$1
    export D=$DATE

    for f in `find $DST -type f -name "${D}_*"`; do
        if [ "`date +%u`" = "${SAVE_DOW}" ];then
            ln -f $f $SD_WEEKLY/
        fi
        if [ "`date +%d`" = "${SAVE_DOM}" ];then
            ln -f $f $SD_MONTHLY/
        fi
    done
}

# проверка
check_reqs

# архивирование
dump_all $SD_DAILY

# очистка старых архивных копий
if [ "$?" = "0" ];then
    post_clean
fi

# создание ссылок/файлов для weekly|monthly
create_links $SD_DAILY

if [ ! -z "$SM" ]; then
  umount `dirname $SD`
fi

