#!/bin/bash

# set -x

# Configuration file
LAB=kafka.lab
CRED=cred.lab

USERNAME=
CREDFILE=

KAFKA_HEAP_OPTS="-Xmx6G -Xms6G"
KAFKA_VERSION=2.0.0
KAFKA_PACKAGE_DIR=kafka_2.11-${KAFKA_VERSION}
KAFKA_INSTALL_PACKAGE=kafka_2.11-${KAFKA_VERSION}.tgz
KAFKA_PACKAGE_URL=http://mirrors.ibiblio.org/apache/kafka/${KAFKA_VERSION}/${KAFKA_INSTALL_PACKAGE}
LOGDIR=/kafka-logs
DATADIR=/zookeeper

execute_remote_cmd() {
    ip="$1"
    cmd="$2"
    sudo="$3"

    if [[ -z "${sudo}" ]]; then
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -i ${CREDFILE} $USERNAME@${ip} "${cmd}"
    else
        # sudo
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -i ${CREDFILE} $USERNAME@${ip} -t -t "${cmd}"
    fi
}

print_msg() {
    datetime=`date "+%Y-%m-%d %H:%M:%S"`
    echo "$datetime: $1"
}

read_user_cred() {
    i=0
    while IFS='' read -r line || [[ -n $line ]]; do
        setting=`echo $line | grep -v \#`
        if [[ "$setting" != "" ]]; then
            ((i++))
            if [[ $i == 1 ]]; then
                USERNAME=$setting
            elif [[ $i == 2 ]]; then
                CREDFILE=$setting
            fi
        fi
    done < ${CRED}
    # print_msg "Use username=$USERNAME, CREDFILE=$CREDFILE to do deployment"
}

download_kafka_package() {
    if [ ! -e $KAFKA_INSTALL_PACKAGE ]; then
        wget ${KAFKA_PACKAGE_URL}
    else
        echo "$KAFKA_INSTALL_PACKAGE is already downloaded"
    fi
}

get_zookeeper_server_list() {
    i=0
    newline=$'\n'
    server_list=""
    while IFS='' read -r line || [[ -n $line ]]; do
        ip=`echo ${line} | grep -v \# | awk -F\| '{print $2}'`
        if [ "${ip}" == "" ]; then
            continue
        fi

        ((i++))
        if [ "${server_list}" == "" ]; then
            server_list="server.${i}=${ip}:2888:3888"
        else
            server_list="${server_list}${newline}server.${i}=${ip}:2888:3888"
        fi
    done < ${LAB}
    echo "${server_list}"
}

get_zookeeper_connect_setting() {
    zookeeper_list=""

    while IFS='' read -r line || [[ -n $line ]]; do
        ip=`echo $line | grep -v \# | awk -F\| '{print $2}'`
        if [ "$ip" == "" ]; then
            continue
        fi

        if [ "$zookeeper_list" == "" ]; then
            zookeeper_list="$ip:2181"
        else
            zookeeper_list="$zookeeper_list,$ip:2181"
        fi
    done < ${LAB}
    echo "$zookeeper_list"
}

configure_zookeeper_settings() {
    # zookeeper.properties
    # initLimit=5
    # syncLimit=2
    # server.1=10.66.128.170:2888:3888
    # dataDir=/zookeeper

    echo "tickTime=2000" >> "${KAFKA_PACKAGE_DIR}/config/zookeeper.properties"
    echo "initLimit=5" >> "${KAFKA_PACKAGE_DIR}/config/zookeeper.properties"
    echo "syncLimit=2" >> "${KAFKA_PACKAGE_DIR}/config/zookeeper.properties"
    echo "$1" >> "${KAFKA_PACKAGE_DIR}/config/zookeeper.properties"
    sed -i "" "s#dataDir=.*#dataDir=${DATADIR}#g" "${KAFKA_PACKAGE_DIR}/config/zookeeper.properties"
}

configure_kafka_server_settings() {
    # kafka server
    # broker.id=0
    # listeners=PLAINTEXT:0.0.0.0//:9092
    # advertised.listeners=PLAINTEXT://<public-ip>:9092
    # log.dirs=/kafka-logs
    # num.partitions=3
    # default.replication.factor=3
    # zookeeper.connect=10.66.128.170:2181,10.66.128.175:2181..
    # zookeeper.connection.timeout.ms=6000
    # delete.topic.enable=true

    id=$1
    ip=$2
    pub_ip=$3
    zk_connect=$4

    sed -i "" "s#broker.id=.*#broker.id=${id}#g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    sed -i "" "s/#host.name=.*/host.name=${ip}/g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    sed -i "" "s/host.name=.*/host.name=${ip}/g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    sed -E -i "" "s@^#?advertised.listeners=PLAINTEXT://.+:9092@advertised.listeners=PLAINTEXT://${pub_ip}:9092@g" "${KAFKA_PACKAGE_DIR}/config/server.properties"

    sed -i "" "s#log.dirs=.*#log.dirs=${LOGDIR}#g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    sed -i "" "s#zookeeper.connect=.*#zookeeper.connect=${zk_connect}#g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    sed -i "" "s#num.partitions=.*#num.partitions=3#g" "${KAFKA_PACKAGE_DIR}/config/server.properties"
    if [  "${id}" == "0" ]; then
        sed -E -i "" 's@^#?listeners=PLAINTEXT://.*:9092@listeners=PLAINTEXT://0.0.0.0:9092@g' "${KAFKA_PACKAGE_DIR}/config/server.properties"
        echo "default.replication.factor=1" >> "${KAFKA_PACKAGE_DIR}/config/server.properties"
        echo "delete.topic.enable=true" >> "${KAFKA_PACKAGE_DIR}/config/server.properties"
        echo "auto.create.topics.enable=true" >> "${KAFKA_PACKAGE_DIR}/config/server.properties"
    fi
}

deploy_kafka_package() {
    rm -rf $KAFKA_PACKAGE_DIR
    tar xzf $KAFKA_INSTALL_PACKAGE
    zk_server_list=`get_zookeeper_server_list`
    zk_connect_str=`get_zookeeper_connect_setting`

    configure_zookeeper_settings "${zk_server_list}"

    id=0
    for ip in `cat ${LAB} | grep -v \#`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        pub_ip=`echo $ip | awk -F\| '{print $1}'`
        private_ip=`echo $ip | awk -F\| '{print $2}'`

        configure_kafka_server_settings "${id}" "${private_ip}" "${pub_ip}" "${zk_connect_str}"
        ((id++))
        print_msg "Deploy kafka package to ${pub_ip}"
        rsync -raz -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -i $CREDFILE" --exclude=macos --delete $KAFKA_PACKAGE_DIR $USERNAME@$pub_ip:~/
        execute_remote_cmd "${pub_ip}" "sudo mkdir -p ${DATADIR};sudo chown ${USERNAME}:${USERNAME} ${DATADIR};echo ${id} > ${DATADIR}/myid" "yes"
        execute_remote_cmd "${pub_ip}" "sudo mkdir -p ${LOGDIR};sudo chown ${USERNAME}:${USERNAME} ${LOGDIR}" "yes"
    done
}

check_kafka_cluster() {
    for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "Check Zookeeper on ${ip}"
        status=`execute_remote_cmd "${ip}" "ps ax | grep -i 'zookeeper' | grep java | grep -v grep | awk '{print \\$1}'"`
        if [ "$status" != "" ]; then
            print_msg "Zookeeper is up and running on ${ip}"
        else
            print_msg "Zookeeper is not running on ${ip}"
            if [[ "$1" == "fix" ]]; then
                start_server "zookeeper" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/zookeeper-server-start.sh config/zookeeper.properties > zookeeper_start.log 2>&1 &" "${ip}"
            fi
        fi

        print_msg "Check Kafka on ${ip}"
        status=`execute_remote_cmd "${ip}" "ps ax | grep -i 'kafka\.Kafka' | grep java | grep -v grep | awk '{print \\$1}'"`
        if [ "$status" != "" ]; then
            print_msg "Kafka is up and running on ${ip}"
        else
            print_msg "Kafka is not running on ${ip}"
            if [[ "$1" == "fix" ]]; then
                start_server "kafka" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/kafka-server-start.sh config/server.properties > kafka_start.log 2>&1 &" "${ip}"
            fi
        fi
    done
}

start_server() {
    # $1 is the tag
    # $2 is the cmd
    # $3 is the ip

    if [[ "$3" == "" ]]; then
        for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
        do
            if [ "${ip}" == "" ]; then
                continue
            fi

            print_msg "Start $1 on ${ip}"
            execute_remote_cmd "${ip}" "$2"
        done
    else
        print_msg "Start $1 on $3"
        execute_remote_cmd "${3}" "$2"
    fi
}

start_kafka_cluster() {
    start_server "zookeeper" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/zookeeper-server-start.sh config/zookeeper.properties > zookeeper_start.log 2>&1 &" "$1"
    sleep 10
    start_server "kafka" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/kafka-server-start.sh config/server.properties > kafka_start.log 2>&1 &" "$1"
}

stop_kafka_cluster() {
    if [[ "$1" == "" ]]; then
        for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
        do
            if [ "${ip}" == "" ]; then
                continue
            fi

            print_msg "Stop kafka on ${ip}"
            execute_remote_cmd "${ip}" "ps ax | grep -i 'kafka\.Kafka' | grep java | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
            execute_remote_cmd "${ip}" "ps ax | grep -i 'zookeeper' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
        done
    else
        print_msg "Stop kafka on $1"
        execute_remote_cmd "$1" "ps ax | grep -i 'zookeeper' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
        execute_remote_cmd "$1" "ps ax | grep -i 'zookeeper' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
    fi
}

restart_kafka_cluster() {
    stop_kafka_cluster
    start_kafka_cluster
}

clear_kafka_env() {
    stop_kafka_cluster
    for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "Clear kafka env on ${ip}"
        execute_remote_cmd "${ip}" "rm -rf ${LOGDIR}/*"
        execute_remote_cmd "${ip}" "rm -rf ${DATADIR}/version*"
    done
    start_kafka_cluster
}

list_kafka_topics() {
    zk_connect=`get_zookeeper_connect_setting`
    for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "List kafka topics"
        execute_remote_cmd "${ip}" "./$KAFKA_PACKAGE_DIR/bin/kafka-topics.sh --zookeeper $zk_connect --list"
        break
    done
}

describe_kafka_topic() {
    topic="$1"
    zk_connect=`get_zookeeper_connect_setting`
    for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "Describe kafka ${topic}"
        execute_remote_cmd "${ip}" "./$KAFKA_PACKAGE_DIR/bin/kafka-topics.sh --zookeeper $zk_connect --describe --topic ${topic}"
        break
    done
}

clear_kafka_topics() {
    zk_connect=`get_zookeeper_connect_setting`
    for ip in `cat ${LAB} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "Clean kafka topics"
        execute_remote_cmd "${ip}" "for topic in \`./$KAFKA_PACKAGE_DIR/bin/kafka-topics.sh --zookeeper $zk_connect --list\`; do ./$KAFKA_PACKAGE_DIR/bin/kafka-topics.sh --delete --zookeeper $zk_connect --topic \$topic; done"
        break
    done
}

usage() {
cat << EOF
Usage: $0 options

    OPTIONS:
    --help    Show this message
    --download # Download kafka installation package
    --deploy
    --start
    --stop
    --clear           # Remove all the data of kafka and zookeeper
    --clear-topics    # Remove all the data of kafka and zookeeper
    --topics          # List topics
    --describe-topic <topic>    # Describe topic
    --restart
    --check <fix|nofix>
EOF
exit 1
}

for arg in "$@"; do
    shift
    case "$arg" in
        "--help")
            set -- "$@" "-h"
            ;;
        "--start")
            set -- "$@" "-s"
            ;;
        "--restart")
            set -- "$@" "-r"
            ;;
        "--stop")
            set -- "$@" "-p"
            ;;
        "--deploy")
            set -- "$@" "-d"
            ;;
        "--check")
            set -- "$@" "-c"
            ;;
        "--clear")
            set -- "$@" "-l"
            ;;
        "--topics")
            set -- "$@" "-o"
            ;;
        "--describe-topic")
            set -- "$@" "-i"
            ;;
        "--clear-topics")
            set -- "$@" "-t"
            ;;
        "--download")
            set -- "$@" "-n"
            ;;
        *)
            set -- "$@" "$arg"
    esac
done

cmd=
ips=
fix=
topic=

while getopts "hsropdlnc:i:" OPTION
do
    case $OPTION in
        h)
            usage
            ;;
        n)
            cmd="download"
            ;;
        d)
            cmd="deploy"
            ;;
        s)
            cmd="start"
            ;;
        p)
            cmd="stop"
            ;;
        r)
            cmd="restart"
            ;;
        l)
            cmd="clear"
            ;;
        o)
            cmd="topics"
            ;;
        i)
            cmd="describe_topic"
            topic="$OPTARG"
            ;;
        t)
            cmd="clear_topics"
            ;;
        c)
            cmd="check"
            fix="$OPTARG"
            ;;
        *)
            usage
            ;;
    esac
done


read_user_cred

if [ "${USERNAME}" == "" ] || [ "${CREDFILE}" == ""  ]; then
    print_msg "Credentials are not found in ${CRED} file"
    exit 1
fi

if [[ "$cmd" == "download" ]]; then
    download_kafka_package
elif [[ "$cmd" == "deploy" ]]; then
    deploy_kafka_package
elif [[ "$cmd" == "start" ]]; then
    start_kafka_cluster
elif [[ "$cmd" == "stop" ]]; then
    stop_kafka_cluster
elif [[ "$cmd" == "restart" ]]; then
    restart_kafka_cluster
elif [[ "$cmd" == "clear" ]]; then
    clear_kafka_env
elif [[ "$cmd" == "clear-topics" ]]; then
    clear_kafka_topics
elif [[ "$cmd" == "topics" ]]; then
    list_kafka_topics
elif [[ "$cmd" == "describe_topic" ]]; then
    describe_kafka_topic "${topic}"
elif [[ "$cmd" == "check" ]]; then
    check_kafka_cluster "${fix}"
else
    usage
fi