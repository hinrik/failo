#!/bin/sh

# Exit on errors
trap 'fail' ERR
fail () {
    code=$?
    echo "Failed with exit code $code"
    exit 1
}

brain=/var/tmp/ramdisk/failo/failo.sqlite
ok=/var/tmp/ramdisk/failo/failo.trained
dir="$(dirname $brain)"

mkdir -p $dir
mkdir -p $dir/trn

for log in '/home/avar/.irssi/logs/freenode/#avar.log ' '/home/avar/.irssi/logs/freenode/#failo.log ' '/home/avar/.irssi/logs/freenode/#hailo.log '; do
    short=$(echo $log | sed 's/.*\#//; s/\.log\s*//')
    to=$dir/trn/$short.trn
    echo "Training from '$log' to $to"
    pv "$log" | irchailo-seed -f irssi -b failo -n failo -r '^,\w' >$to
done

pv $dir/trn/*.trn > $dir/trn/all.trn

echo "Creating a new brain at $brain"
hailo \
    --brain $brain \
    --train $dir/trn/all.trn \
    --order 2

# Indicate that we're done training
echo "Done training, creating $ok"
>$ok
