#!/bin/ksh

# olbohlen, 2016-10-27
# this is a script that mirrors existing IPS/pkg5 repositories to local copy
# it handles automatic zfs cloning, so we can update our local copies without
# disrupting our own package service


log_msg() {
    # log messages to a file for later review, also write to stdout
    typeset my_tstamp
    typeset my_logfile
    typeset my_level
    typeset my_msg

    my_level="$1"
    my_msg="$2"

    my_tstamp=$(date "+%b %e %H:%M:%S")
    my_logfile=/var/log/pkg5mirror.log

    printf "%s %s pkg5mirror[%s] %s: %s\n" "${my_tstamp}" "$(uname -n)" $$ "${my_level}" "${my_msg}" >>"${my_logfile}"
}

usage() {
    cat <<EOF
Usage: 
       $0 -r repoid -o origin [ -n ] [ -p proxy ] [ -k /path/to/key ] [ -c /path/to/cert ]

          -n    don't use --clone for pkgrecv to avoid a bug in Hipsters pkgrecv

Example: 
       $0 -r hipster -o https://pkg.openindiana.org/hipster/ -p http://webproxy.corp.com:8080/
       $0 -r solaris -o https://pkg.oracle.com/solaris/support/ -n -p http://webproxy.corp.com:8080/ -k /var/pkg/client.key -c /var/pkt/client.crt
EOF
    exit 1
}

## main ##
typeset repofs
typeset publisher
typeset pubprefix
typeset smfid
typeset snaptag
typeset cmd_out
typeset pkgrecvout
typeset pkgorigin
typeset counter
typeset certargs
typeset keyargs
typeset noclone

while getopts hr:o:c:k:p:n argv; do
    case ${argv} in
	h)            usage;;
	p)            http_proxy=${OPTARG}
	              https_proxy=${OPTARG}
		      export http_proxy https_proxy;;
	c)            certargs=" --cert ${OPTARG}";;
	k)            keyargs=" --key ${OPTARG}";;
	r)            publisher=${OPTARG};;
	o)            pkgorigin=${OPTARG};;
	n)            noclone=TRUE;;
	*)            usage;;
    esac
done
shift $(( ${OPTIND} - 1 ))

# test if mandatory arguments are provided
if [ x${publisher} == x -o "x${pkgorigin}" == x ]; then
    log_msg ERROR "stop: -r and/or -o not supplied"
    exit 1
fi

smfid=svc:/application/pkg/server:${publisher}
svcs -- ${smfid} >/dev/null 2>&1
if [ $? -gt 0 ]; then
    log_msg ERROR "service ${smfid} unknown"
    exit 1
fi

repofs=$(/usr/sbin/svccfg -s ${smfid} listprop pkg/inst_root | nawk '{print $3}')
repods=$(df -k ${repofs} | nawk '$0~/\//  { print $1 }')
snaptag=@pkg5mirror-$(date +"%Y-%m-%d_%H-%M-%S")

pkgrecvout=/tmp/pkgrecv-$$.out
counter=0

log_msg INFO "starting pkg5mirror for ${publisher}"

# find old snapshots and destroy them
for snap in $(/usr/sbin/zfs list -t snapshot -H -o name -r ${repods} | egrep "@pkg5mirror-"); do
    log_msg INFO "deleting old snapshot ${snap}"
    cmd_out=$( /usr/sbin/zfs destroy ${snap} 2>&1 ) 
    if [ $? -gt 0 ]; then
	log_msg ERROR "zfs destroy ${snap} has returned an error: ${cmd_out}"
    fi
done

# now snapshot original repofs
log_msg INFO "creating snapshot ${repods}${snaptag}"
cmd_out=$( /usr/sbin/zfs snapshot ${repods}${snaptag} 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "zfs snapshot ${repods}${snaptag} returned an error: ${cmd_out}"
    exit 1
fi

# now clone our snap
log_msg INFO "cloning zfs ${repods}${snaptag} to ${repods}-clone"
cmd_out=$( /usr/sbin/zfs clone ${repods}${snaptag} ${repods}-clone 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "zfs clone ${repods}${snaptag} ${repods}-clone returned an error: ${cmd_out}"
    exit 1
fi

# get the default publisher name from repository
pubprefix=$( pkgrepo -s file://${repofs}-clone get -H publisher/prefix | nawk '{ print $3 }' )

if [ x${noclone} == xTRUE ]; then
    # don't use --clone as Hipsters pkgrecv cannot verify pkg signatures from oracle then
    # at this point we will receive updates to the repository
    log_msg INFO "now starting pkgrecv for ${pubprefix}"
    pkgrecv -s ${pkgorigin} -d file://${repofs}-clone ${certargs} ${keyargs} '*' >${pkgrecvout} 2>&1 
    if [ $? -gt 0 ]; then
	log_msg ERROR "pkgrecv -s ${pkgorigin} -d file://${repofs}-clone ${certargs} ${keyargs} '*' returned an error"
	exit 1
    fi
else
    # at this point we will receive updates to the repository
    log_msg INFO "now starting pkgrecv --clone for ${pubprefix}"
    pkgrecv -p ${pubprefix} -s ${pkgorigin} -d file://${repofs}-clone --clone >${pkgrecvout} 2>&1 
    if [ $? -gt 0 ]; then
	log_msg ERROR "pkgrecv -p ${pubprefix} -s ${pkgorigin} -d file://${repofs}-clone --clone returned an error"
	exit 1
    fi
fi

# now refresh the cloned and updated repo
log_msg INFO "refreshing file://${repofs}-clone"
cmd_out=$( pkgrepo refresh -s file://${repofs}-clone 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "pkgrepo refresh -s file://${repofs}-clone returned an error: ${cmd_out}"
    exit 1
fi

# promote the clone, so we can delete the original fs
log_msg INFO "promoting ${repods}-clone"
cmd_out=$( /usr/sbin/zfs promote ${repods}-clone 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "zfs promote ${repods}-clone returned an error: ${cmd_out}"
    exit 1
fi

# now stop pkg instance
log_msg INFO "disabling ${smfid}"
cmd_out=$( sudo /usr/sbin/svcadm disable ${smfid} 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "unable to disable ${smfid}: ${cmd_out}"
    exit 1
fi

# wait till service is stopped

while [ x$(svcs -H -o state ${smfid} 2>/dev/null) != xdisabled ] ; do
    
    if [ ${counter} -lt 8 ]; then
	sleep $(( 2**${counter} ))
    else
	log_msg ERROR "unable to stop ${smfid} within 255seconds, exiting"
	exit 1
    fi
    counter=$(( ${counter} + 1 ))
done

# delete our origin fs
log_msg INFO "deleting origin ds ${repods}"
cmd_out=$( /usr/sbin/zfs destroy ${repods} 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "zfs destroy of origin ds failed: ${cmd_out}"
    exit 1
fi


# now rename our clone to original fs
log_msg INFO "renaming clone to origin fs"
cmd_out=$( /usr/sbin/zfs rename ${repods}-clone ${repods} 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "zfs rename failed: ${cmd_out}"
    exit 1
fi

# now stop pkg instance
cmd_out=$( sudo /usr/sbin/svcadm enable ${smfid} 2>&1 )
if [ $? -gt 0 ]; then
    log_msg ERROR "unable to enable ${smfid}: ${cmd_out}"
    exit 1
fi

# write finish notice
log_msg INFO "job complete"

