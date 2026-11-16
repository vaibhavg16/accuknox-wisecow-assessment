#!/usr/bin/env bash

SRVPORT=4499
RSPFILE=/tmp/response

rm -f $RSPFILE
mkfifo $RSPFILE

get_api() {
    read line
    echo $line
}

handleRequest() {
    get_api
    mod=$(fortune)

cat <<EOF > $RSPFILE
HTTP/1.1 200

<pre>$(cowsay "$mod")</pre>
