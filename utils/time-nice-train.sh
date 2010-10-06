#!/bin/sh

rm -rf /var/tmp/ramdisk/failo
echo "no nice"
time /home/failo/failo/utils/retrain-on-reboot.sh

rm -rf /var/tmp/ramdisk/failo
echo "nice"
time nice -n 19 /home/failo/failo/utils/retrain-on-reboot.sh

rm -rf /var/tmp/ramdisk/failo
echo "ionice"
time ionice -c 3 /home/failo/failo/utils/retrain-on-reboot.sh

rm -rf /var/tmp/ramdisk/failo
echo "nice+ionice"
time nice -n 19 ionice -c 3 /home/failo/failo/utils/retrain-on-reboot.sh

echo "done"
