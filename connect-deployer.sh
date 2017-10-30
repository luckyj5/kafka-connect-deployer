#!/bin/bash

# set -x

# Configuration file
LAB=kafka.lab
LAB2=connect.lab
CRED=cred.lab


USERNAME=
CREDFILE=

KAFKA_HEAP_OPTS="-Xmx6G -Xms6G"
KAFKA_VERSION=0.11.0.1
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

#get list of bootstrap servers
get_kafka_server_list() {
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
            server_list="${ip}:9092"
        else
            server_list=${server_list},"${ip}:9092"
        fi
    done < ${LAB}
    echo "${server_list}"
}

configure_connect_settings() {
 
    #connect-distributed.properties
    # bootstrap.servers=localhost1:9092,localhost2:9092 etc
    # group.id=connect-cluster
    # key.converter.schemas.enable=false
    # value.converter.schemas.enable=false

    print_msg ${server_list}
    sed -i "" "s#bootstrap.servers=.*#bootstrap.servers=${k_server_list}#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
    sed -i "" "s#group.id=.*#group.id=connect-cluster#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
    sed -i "" "s#key.converter.schemas.enable=true#key.converter.schemas.enable=false#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
    sed -i "" "s#value.converter.schemas.enable=true#value.converter.schemas.enable=false#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
    
}


deploy_kafka_package() {
    rm -rf $KAFKA_PACKAGE_DIR
    tar xzf $KAFKA_INSTALL_PACKAGE
    k_server_list=`get_kafka_server_list`

    configure_connect_settings "${k_server_list}"
 
     id=0
     for ip in `cat ${LAB2} | grep -v \#`
     do
         if [ "${ip}" == "" ]; then
             continue
         fi

         pub_ip=`echo $ip | awk -F\| '{print $1}'`
         private_ip=`echo $ip | awk -F\| '{print $2}'`

         configure_connect_settings "${id}" "${private_ip}" "${pub_ip}" "${k_server_list}"
         ((id++))
         print_msg "Deploy kafka-connect package to ${pub_ip}"
         rsync -raz -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -i $CREDFILE" --exclude=macos --delete $KAFKA_PACKAGE_DIR $USERNAME@$pub_ip:~/
        
     done
}

check_kafka_connect_cluster() {
    for ip in `cat ${LAB2} | grep -v \# | awk -F\| '{print $1}'`
    do
        if [ "${ip}" == "" ]; then
            continue
        fi

        print_msg "Check Kafka-connect on ${ip}"
        status=`execute_remote_cmd "${ip}" "curl --write-out %{http_code} --silent --output /dev/null localhost:8083"`
        #print_msg ${status}
        if [ "$status" == 200 ]; then
            print_msg "kafka-connect is up and running on ${ip}"
        else
            print_msg "Kafka-connect is not running on ${ip}"
            if [[ "$1" == "fix" ]]; then
                start_server "zookeeper" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/zookeeper-server-start.sh config/zookeeper.properties > zookeeper_start.log 2>&1 &" "${ip}"
            fi
        fi

    done
}

start_server() {
    # $1 is the tag
    # $2 is the cmd
    # $3 is the ip

    if [[ "$3" == "" ]]; then
        for ip in `cat ${LAB2} | grep -v \# | awk -F\| '{print $1}'`
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

start_kafka_connect_cluster() {
    
    start_server "kafka-connect" "cd $KAFKA_PACKAGE_DIR; export KAFKA_HEAP_OPTS=\"$KAFKA_HEAP_OPTS\"; nohup ./bin/connect-distributed.sh config/connect-distributed.properties > kafka_connect_start.log 2>&1 &" "$1"
}

stop_kafka_connect_cluster() {
    if [[ "$1" == "" ]]; then
        for ip in `cat ${LAB2} | grep -v \# | awk -F\| '{print $1}'`
        do
            if [ "${ip}" == "" ]; then
                continue
            fi

            print_msg "Stop kafka connect on ${ip}"
            execute_remote_cmd "${ip}" "ps ax | grep -i 'connect' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
        done
    else
        print_msg "Stop kafka on $1"
        execute_remote_cmd "$1" "ps ax | grep -i 'connect' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
        execute_remote_cmd "$1" "ps ax | grep -i 'connect' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
    fi
}

restart_kafka_connect_cluster() {
    stop_kafka_connect_cluster
    start_kafka_connect_cluster
}


usage() {
cat << EOF
Usage: $0 options

    OPTIONS:
    --help    Show this message
    --download # Download kafka-connect installation package
    --deploy  # Configure kafka connect package
    --start 
    --stop
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
    start_kafka_connect_cluster
elif [[ "$cmd" == "stop" ]]; then
    stop_kafka_connect_cluster
elif [[ "$cmd" == "restart" ]]; then
    restart_kafka_connect_cluster
elif [[ "$cmd" == "check" ]]; then
    check_kafka_connect_cluster "${fix}"
else
    usage
fi
