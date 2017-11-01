#!/bin/bash

# set -x

# Configuration file
KAFKALAB=kafka.lab
CONNECTLAB=connect.lab
CRED=cred.lab


USERNAME=
CREDFILE=


KAFKA_HEAP_OPTS="-Xmx6G -Xms6G"
KAFKA_VERSION=0.11.0.1
KAFKA_PACKAGE_DIR=/home/ec2-user/kafka-connect-splunk
PROC_MONITOR=/home/ec2-user/proc_monitor
KAKFA_BUILD_DIR=/tmp/kafka-connect-splunk-build/
KAFKA_INSTALL_PACKAGE=kafka_2.11-${KAFKA_VERSION}.tgz
KAFKA_PACKAGE_URL=http://mirrors.ibiblio.org/apache/kafka/${KAFKA_VERSION}/${KAFKA_INSTALL_PACKAGE}
curdir=`pwd`
#echo ${curdir}

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
    done < ${KAFKALAB}
    echo "${server_list}"
}

configure_connect_settings() {
 
    #connect-distributed.properties
    # bootstrap.servers=localhost1:9092,localhost2:9092 etc
    # group.id=connect-cluster
    # key.converter.schemas.enable=false
    # value.converter.schemas.enable=false

    print_msg ${server_list}
    sed -i "" "s#bootstrap.servers=.*#bootstrap.servers=${k_server_list}#g" "${curdir}/kafka-connect-splunk/kafka-connect-splunk/config/connect-distributed.properties"
    sed -i "" "s#rest.advertised.host.name=.*#\#rest.advertised.host.name=#g" "${curdir}/kafka-connect-splunk/kafka-connect-splunk/config/connect-distributed.properties"
    sed -i "" "s#rest.host.name=.*#\#rest.host.name=#g" "${curdir}/kafka-connect-splunk/kafka-connect-splunk/config/connect-distributed.properties"
    sed -i "" "s#status.storage.partitions=.*#status.storage.partitions=5#g" "${curdir}/kafka-connect-splunk/kafka-connect-splunk/config/connect-distributed.properties"
    sed -i "" "s#offset.storage.partitions=.*#offset.storage.partitions=25#g" "${curdir}/kafka-connect-splunk/kafka-connect-splunk/config/connect-distributed.properties"
  #  sed -i "" "s#key.converter.schemas.enable=true#key.converter.schemas.enable=false#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
  #  sed -i "" "s#value.converter.schemas.enable=true#value.converter.schemas.enable=false#g" "${KAFKA_PACKAGE_DIR}/config/connect-distributed.properties"
    
}

build_kafka_package() {
    
    git clone https://github.com/splunk/kafka-connect-splunk.git
    cd kafka-connect-splunk
    git checkout develop
    git pull
    bash build.sh

}

deploy_kafka_package() {
    #curdir = 'pwd'/kafka-connect-splunk
    
    cd ${curdir}/kafka-connect-splunk
    tar xzf ${curdir}/kafka-connect-splunk/kafka-connect-splunk.tar.gz
    cd ${curdir}

    k_server_list=`get_kafka_server_list`

    configure_connect_settings "${k_server_list}"
 
     for ip in `cat ${CONNECTLAB} | grep -v \#`
     do
         if [ "${ip}" == "" ]; then
             continue
         fi

         pub_ip=`echo $ip | awk -F\| '{print $1}'`

         print_msg "Deploy kafka-connect package to ${pub_ip}"
         
         rsync -raz -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -i $CREDFILE" --exclude=macos ${curdir}/kafka-connect-splunk/kafka-connect-splunk $USERNAME@$pub_ip:~/
         execute_remote_cmd "${pub_ip}" "export KAFKA_HEAP_OPTS='-Xmx6G -Xms2G'"
         execute_remote_cmd "${pub_ip}" "sudo wget -q --no-check-certificate --no-cookies --header \"Cookie: oraclelicense=accept-securebackup-cookie\" http://download.oracle.com/otn-pub/java/jdk/8u141-b15/336fa29ff2bb4ef291e347e091f7f4a7/jdk-8u141-linux-x64.rpm"
         execute_remote_cmd "${pub_ip}" "sudo yum install -y jdk-8u141-linux-x64.rpm"

     done
}

check_kafka_connect_cluster() {
    for ip in `cat ${CONNECTLAB} | grep -v \# | awk -F\| '{print $1}'`
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
        fi

    done
}

start_server() {
    # $1 is the tag
    # $2 is the cmd
    # $3 is the ip

    if [[ "$3" == "" ]]; then
        for ip in `cat ${CONNECTLAB} | grep -v \# | awk -F\| '{print $1}'`
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
    start_server "proc_monitor" "screen -S proc_monitor -m -d python $PROC_MONITOR/proc_monitor.py &" "$1"
}

stop_kafka_connect_cluster() {
    if [[ "$1" == "" ]]; then
        for ip in `cat ${CONNECTLAB} | grep -v \# | awk -F\| '{print $1}'`
        do
            if [ "${ip}" == "" ]; then
                continue
            fi

            print_msg "Stop kafka connect on ${ip}"
            execute_remote_cmd "${ip}" "ps ax | grep -i 'connect' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
            print_msg "Stop proc_monitor on ${ip}"
            execute_remote_cmd "${ip}" "ps ax | grep -i 'monitor' | grep -v grep | xargs kill -9 > /dev/null 2>&1"
        done
    else
        print_msg "Stop kafka connect on $1"
        execute_remote_cmd "$1" "ps ax | grep -i 'connect' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
        print_msg "Stop proc_monitor on $1"
        execute_remote_cmd "$1" "ps ax | grep -i 'monitor' | grep -v grep | awk '{print \$1}' | xargs kill -9 > /dev/null 2>&1"
    fi
}

restart_kafka_connect_cluster() {
    stop_kafka_connect_cluster
    start_kafka_connect_cluster
}


clean_kafka_connect_cluster() {
    if [[ "$1" == "" ]]; then
        for ip in `cat ${CONNECTLAB} | grep -v \# | awk -F\| '{print $1}'`
        do
            if [ "${ip}" == "" ]; then
                continue
            fi

            print_msg "Cleaning kafka connect on ${ip}"
            execute_remote_cmd "${ip}" "rm -rf /home/ec2-user/kafka-connect-splunk/*"
        done
    else
        print_msg "Kafka Connect doesn't exist on $1"
    fi


}


usage() {
cat << EOF
Usage: $0 options

    OPTIONS:
    --help    Show this message
    --build # Build kafka-connect package
    --deploy  # Configure kafka connect package
    --start 
    --stop
    --restart
    --clean
    --check
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
        "--create-topic")
            set -- "$@" "-l"
            ;;
        "--topics")
            set -- "$@" "-o"
            ;;
        "--describe-topic")
            set -- "$@" "-i"
            ;;
        "--clean")
           set -- "$@" "-t"
           ;;
        "--build")
            set -- "$@" "-n"
            ;; 
        *)
            set -- "$@" "$arg"
    esac
done

cmd=
ips=
topic=
#topics1=

while getopts "hsropdlnci:" OPTION
do
    case $OPTION in
        h)
            usage
            ;;
        n)
            cmd="build"
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
#        l)
#           cmd="create-topic"
#          topics1="$OPTARG"
#            ;;
        o)
            cmd="topics"
            ;;
        i)
            cmd="describe_topic"
            topic="$OPTARG"
            ;;
        t)
            cmd="clean"
            ;;
        c)
            cmd="check"
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

if [[ "$cmd" == "build" ]]; then
    build_kafka_package   
elif [[ "$cmd" == "deploy" ]]; then
    deploy_kafka_package
elif [[ "$cmd" == "start" ]]; then
    start_kafka_connect_cluster
elif [[ "$cmd" == "stop" ]]; then
    stop_kafka_connect_cluster
elif [[ "$cmd" == "restart" ]]; then
    restart_kafka_connect_cluster
elif [[ "$cmd" == "check" ]]; then
    check_kafka_connect_cluster
elif [[ "$cmd" == "clean" ]]; then
    clean_kafka_connect_cluster
else
    usage
fi
