#!/bin/sh

# Exit on errors
trap 'fail' ERR
fail () {
    code=$?
    echo "Failed with exit code $code"
    exit 1
}

log='/home/avar/.irssi/logs/freenode/#avar.log '
brain=/var/tmp/ramdisk/failo/failo.sqlite
ok=/var/tmp/ramdisk/failo/failo.trained
dir="$(dirname $brain)"
trn="$dir/avar.trn"

mkdir -p $dir

echo "Training from '$log' to $trn"
pv "$log" | irchailo-seed -f irssi -b failo -n failo -r '^,\w' >$trn

echo "Creating a new brain at $brain"
hailo \
    --brain $brain \
    --train $trn \
    --order 2

# Indicate that we're done training
echo "Done training, creating $ok"
>$ok
