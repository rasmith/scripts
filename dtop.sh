#!/bin/bash

kill=0
grep_command=

while [[ $# -gt 0 ]] ; do
  i=$1
  case $i in
  --kill)
    kill=1
  ;;
  -v)
    grep_command="$2"
    shift
  ;;
  esac
  shift
done

if command -v nvidia-smi &> /dev/null ; then
    pids=$(nvidia-smi -q -d PIDS | grep "Process ID" | tr -s ' ' | cut -d: -f2)
elif command -v rocm-smi &> /dev/null ; then
    pids=$(/opt/rocm/bin/rocm-smi --showpids | egrep "^[0-9]" | awk '{print $1}')
else
    echo "No GPU found"
    exit 1
fi

cids=()

for pid in $pids ; do
    echo "PID: ${pid}"

    new_cids=$(for cid_name in $(docker ps --format "{{.ID}}:{{.Names}}") ; do cid=$(echo $cid_name | cut -d':' -f1) ; name=$(echo $cid_name | cut -d':' -f2) docker top $cid | grep $pid > /dev/null && echo "${cid_name}" ; done)
    for new_cid_name in $new_cids ; do
        new_cid=$(echo $new_cid_name | cut -d':' -f1)
        echo "Container: $new_cid_name"
        if [[ -n $grep_command && $new_cid_name =~ $grep_command ]] ; then
          echo "Matched $grep_command"
          continue
        fi
        cids+=( $new_cid )
    done
done
echo "Result"
sorted_unique_cids=($(echo "${cids[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

for cid in ${sorted_unique_cids[@]} ; do
    echo "Container ID: ${cid}"
    if [[ $kill -eq 1 ]] ; then
      echo "Killing $cid"
      docker kill $cid
    fi
    docker inspect $cid | grep home | tr -s ' ' | head -1
done