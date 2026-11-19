#!/bin/bash
# 64000 MiB backend capacity needs >= 32000 x 2MiB pages; keep headroom.
echo 40960 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
