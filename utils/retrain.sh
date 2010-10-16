#!/bin/sh

# Exit on errors
trap 'fail' ERR
fail () {
    code=$?
    echo "Failed with exit code $code"
    exit 1
}

logit () {
    date +"%Y-%m-%d %H:%M:%S" | tr -d '\n'
    echo -n " -> "
    echo "$@"
}


brain=/var/tmp/ramdisk/failo/failo.sqlite
ok=/var/tmp/ramdisk/failo/failo.trained
dir="$(dirname $brain)"

mkdir -p $dir
mkdir -p $dir/trn

for log in '/home/avar/.irssi/logs/freenode/#avar.log ' '/home/avar/.irssi/logs/freenode/#failo.log ' '/home/avar/.irssi/logs/freenode/#hailo.log '; do
    short=$(echo $log | sed 's/.*\#//; s/\.log\s*//')
    to=$dir/trn/$short.trn
    logit "Training from '$log' to $to"
    pv "$log" | irchailo-seed -f irssi -b failo -n failo -r '^,\w' >$to
done

pv $dir/trn/*.trn > $dir/trn/all.trn

logit "Creating a new brain at $brain"
hailo \
    --brain $brain \
    --train $dir/trn/all.trn \
    --order 2

logit "Removing temporary files"
rm -rfv $dir/trn

# Indicate that we're done training
logit "Done training, creating $ok"
>$ok
