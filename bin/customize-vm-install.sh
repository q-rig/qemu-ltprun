#! /bin/sh

ROOT_DIR=$1
IMG_NAME=$2

rm -rf $ROOT_DIR/usr/share/doc
df -h | grep $ROOT_DIR
