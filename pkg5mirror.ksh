#!/bin/ksh

# olbohlen, 2016-10-27
# this is a script that mirrors existing IPS/pkg5 repositories to local copy
# it handles automatic zfs cloning, so we can update our local copies without
# disrupting our own package service

repofs="/var...pkg/hipster"
publisher=""
smfid=""
snaptag=@pkg5mirror-$(date +"%Y-%m-%d_%H-%M-%S")

## main ##

# find old snapshots and destroy them
for snap in $(zfs list -t snapshot -r ${repofs} -H -o name | egrep "${snaptag}"); do
    zfs destroy ${snap}
done

# now snapshot original repofs
zfs snapshot ${repofs}${snaptag}

# now clone our snap
zfs clone ${repofs}${snaptag} ${repofs}-clone

# at this point we will receive updates to the repository
pkgrecv -p ${publisher} -s ${pkgorigin} -d file://${repofs}-clone --clone

# now refresh the cloned and updated repo
pkgrepo refresh -s file://${repofs}-clone

# promote the clone, so we can delete the original fs
zfs promote ${repofs}-clone

# now stop pkg instance
svcadm disable pkg/server:foo

# wait till service is stopped

while svcs pkg/server:foo; do
    sleep 1
done

# now rename our clone to original fs
zfs rename ${repofs}-clone ${repofs}

# now stop pkg instance
svcadm enable pkg/server:foo
