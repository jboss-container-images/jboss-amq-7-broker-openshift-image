#!/bin/sh
set -e

export FILE_NAME=$1

#Remove the server side origin check

sed -i 's/<strict-checking\/>//g' $FILE_NAME