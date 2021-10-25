#!/bin/bash

###################################################
# Centreon                                Juin 2017
#
# Permet de synchroniser en passant par 
#   une sauvegarde binaire
#
###################################################

. /usr/share/centreon-ha/lib/mysql-functions.sh
. /etc/centreon-ha/mysql-resources.sh

usage()
{
echo
echo "Use : $0"
echo
}

cmd_line()
{
	:
}

#
# Main
#
cmd_line $*

###########################################
# SANITY CHECK
###########################################

# minimum Go
VG_FREESIZE_NEEDED=1
STOP_TIMEOUT=60
SNAPSHOT_MOUNT_PATH="/mnt/"
MYSQL_CNF="/etc/my.cnf.d/server.cnf"
USER="mysql"
USER_SUDO="sudo -u $USER"
MYSQLBINARY="mariadbd"
MYSQLADMIN="mysqladmin"
MYSQLBINLOG="mysqlbinlog"
MYSQL_START="/usr/bin/mysqld_safe --defaults-file=/etc/my.cnf.d/server.cnf --pid-file=/var/lib/mysql/mysql.pid --socket=/var/lib/mysql/mysql.sock --datadir=/var/lib/mysql --log-error=/var/log/mysqld.log --user=mysql --skip-slave-start"
SUDO_MYSQL_START_SLAVE="sudo"

if [[ "$USER" == "root" ]] ; then
    USER_SUDO=
    SUDO_MYSQL_START_SLAVE=
fi

###
# Check rsync
###

which rsync > /dev/null
if [ "$?" -ne "0" ] ; then
	echo "ERROR: Need rsync command." >&2
	exit 1
fi

###
# Check MySQL launch
###
process=$(ps -o args --no-headers -C ${MYSQLBINARY})
started=0

###
# Find datadir
###
if [ -n "$process" ] ; then
	datadir=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--datadir")) { print $i } } }' | awk -F\= '{ print $2 }')
	etc_file=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--defaults-file")) { print $i } } }' | awk -F\= '{ print $2 }')
	logbin=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--log-bin")) { print $i } } }' | awk -F\= '{ print $1 }')
	logbin_path=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--log-bin")) { print $i } } }' | awk -F\= '{ print $2 }')
	pidname=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--pid-file")) { print $i } } }' | awk -F\= '{ print $2 }')
	relaylog=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--relay-log")) { print $i } } }' | awk -F\= '{ print $1 }')
	relaylog_path=$(echo "$process" | awk '{ for (i = 1; i < NF; i++) { if (match($i, "--relay-log")) { print $i } } }' | awk -F\= '{ print $2 }')
	started=1
	if [ -n "$etc_file" ] ; then
		MYSQL_CNF="$etc_file"
	fi
fi

if [ -z "$datadir" ] ; then
	datadir=$(cat $MYSQL_CNF | grep -E '^datadir' | awk -F\= '{ print $2; exit 0 }')
fi

if [ -z "$datadir" ] ; then
	echo "ERROR: Can't find MySQL datadir." >&2
	exit 1
fi
### Avoid datadir is a symlink (get the absolute path)
datadir=$(cd "$datadir"; pwd -P)

if [ -z "$pidname" ] ; then
	pidname=$(cat "$MYSQL_CNF" | grep -E '^pid-file' | awk -F\= '{ print $2; exit 0 }')
fi
if [ -z "$pidname" ] ; then
	pidname=$(hostname | cut -d '.' -f 1)
else
	pidname=$(basename "$pidname" | cut -d '.' -f 1)
fi

if [ -z "$logbin" ] ; then
	logbin=$(cat "$MYSQL_CNF" | grep -E '^log-bin' | awk -F\= '{ print $1 }')
	logbin_path=$(cat "$MYSQL_CNF" | grep -E '^log-bin' | awk -F\= '{ print $2 }')
fi
if [ -z "$logbin" ] ; then
	echo "'log-bin' option not found. Can't sync."
	exit 1
else
	if [ -n "$logbin_path" ] ; then
		logbin_files=$(basename "$logbin_path")
		logbin_loc=$(dirname "$logbin_path")
	else
		logbin_files="$pidname-bin"
	fi
	if [ -z "$logbin_loc" ] || [ "$logbin_loc" = "." ] ; then
		logbin_loc="$datadir"
	fi
fi

if [ -z "$relaylog" ] ; then
	relaylog=$(cat "$MYSQL_CNF" | grep -E '^relay-log' | awk -F\= '{ print $1 }')
	relaylog_path=$(cat "$MYSQL_CNF" | grep -E '^relay-log' | awk -F\= '{ print $2 }')
fi
if [ -z "$relaylog" ] ; then
	relaylog_loc="$datadir"
	relaylog_files="$pidname-relay-bin"
else
	if [ -n "$relaylog_path" ] ; then
		relaylog_files=$(basename "$relaylog_path")
		relaylog_loc=$(dirname "$relaylog_path")
	else
		relaylog_files="$pidname-relay-bin"
	fi
	if [ -z "$relaylog_loc" ] ; then
		relaylog_loc="$datadir"
	fi
fi

echo "MySQL datadir found: $datadir"
echo "MySQL logbin files: $logbin_files"
echo "MySQL logbin localisation: $logbin_loc"
echo "MySQL relaylog files: $relaylog_files"
echo "MySQL relaylog localisation: $relaylog_loc"

###
# Find init script
###

###
# Get mount datadir
###
mount_device=$(df -P "$datadir" | tail -1 | awk '{ print $1 }')
mount_point=$(df -P "$datadir" | tail -1 | awk '{ print $6 }')
if [ -z "$mount_device" ] ; then
	echo "ERROR: Can't get mount device for datadir." >&2
	exit 1
fi
if [ -z "$mount_point" ] ; then
	echo "ERROR: Can't get mount point for datadir." >&2
	exit 1
fi
echo "Mount device 'datadir' found: $mount_device"
echo "Mount point 'datadir' found: $mount_point"

###
# Get mount logbin
###
mount_device_logbin=$(df -P "$logbin_loc" | tail -1 | awk '{ print $1 }')
mount_point_logbin=$(df -P "$logbin_loc" | tail -1 | awk '{ print $6 }')
if [ -z "$mount_device_logbin" ] ; then
	echo "ERROR: Can't get mount device for log-bin dir." >&2
	exit 1
fi
if [ -z "$mount_point_logbin" ] ; then
	echo "ERROR: Can't get mount point for log-bin dir." >&2
	exit 1
fi
echo "Mount device 'log-bin' found: $mount_device_logbin"
echo "Mount point 'log-bin' found: $mount_point_logbin"

###
# Get Volume group Name
###
vg_name=$(lvdisplay -c "$mount_device" | cut -d : -f 2)
lv_name=$(lvdisplay -c "$mount_device" | cut -d : -f 1)
if [ -z "$vg_name" ] ; then
	echo "ERROR: Can't get VolumeGroup name for datadir." >&2
	exit 1
fi
if [ -z "$lv_name" ] ; then
	echo "ERROR: Can't get LogicalVolume name for datadir." >&2
	exit 1
fi

vg_name_logbin=$(lvdisplay -c "$mount_device_logbin" | cut -d : -f 2)
lv_name_logbin=$(lvdisplay -c "$mount_device_logbin" | cut -d : -f 1)
if [ -z "$vg_name_logbin" ] ; then
	echo "ERROR: Can't get VolumeGroup name for log-bin dir." >&2
	exit 1
fi
if [ -z "$lv_name_logbin" ] ; then
	echo "ERROR: Can't get LogicalVolume name for log-bin dir." >&2
	exit 1
fi

if [ "$vg_name_logbin" != "$vg_name" ] ; then
	echo "ERROR: log-bin dir and datadir have to be on the same VolumeGroup." >&2
	exit 1
fi

echo "VolumeGroup found: $vg_name"
echo "LogicalVolume 'datadir' found: $lv_name"
echo "LogicalVolume 'log-bin' found: $lv_name_logbin"

###
# Get free Space
###

free_pe=$(vgdisplay -c "$vg_name" | cut -d : -f 16)
size_pe=$(vgdisplay -c "$vg_name" | cut -d : -f 13)
if [ -z "$free_pe" ] ; then
	echo "ERROR: Can't get free PE value for the VolumeGroup." >&2
	exit 1
fi
if [ -z "$size_pe" ] ; then
	echo "ERROR: Can't get size PE value for the VolumeGroup." >&2
	exit 1
fi

free_total_pe=$(echo $free_pe " " $size_pe | awk '{ print ($1 * $2) / 1024 / 1024 }')
echo "Free total size in VolumeGroup (Go): $free_total_pe"

echo "$free_total_pe $VG_FREESIZE_NEEDED" | awk '{ if ($2 > $1) { exit(1) } else { exit(0) } }'
if [ "$?" -eq 1 ] ; then
	echo "ERROR: Not enough free space in the VolumeGroup." >&2
	exit 1
fi

###
# Check slave server stopped
###

slave_hostname=$(get_other_db_hostname)
master_hostname=$(get_other_db_hostname $slave_hostname)
echo "Connection to slave Server (verify mysql stopped): $slave_hostname"
result=$($USER_SUDO ssh $slave_hostname 'if ps --no-headers -C '"$MYSQLBINARY"' >/dev/null; then echo "yes" ; else echo "no"; fi')
if [ "$result" != "no" ] ; then
	echo "ERROR: MySQL is launched or problem to connect to the server." >&2
	exit 1
fi

#############
############# END SANITY CHECK
#############

###########################################
# Beginning
###########################################

###
# We need to stop if need
###
if [ "$started" -eq 1 ] ; then
	i=0
	echo -n "Stopping $MYSQLBINARY:"
    $MYSQLADMIN -f -u "$DBROOTUSER" -h "$master_hostname" -p"$DBROOTPASSWORD" shutdown
	while ps -o args --no-headers -C $MYSQLBINARY >/dev/null; do
		if [ "$i" -gt "$STOP_TIMEOUT" ] ; then
			echo ""
			echo "ERROR: Can't stop MySQL Server" >&2
			exit 1
		fi
		echo -n "."
		sleep 1
		i=$(($i + 1))
	done
	echo "OK"
fi

###
# Do snapshot
###
echo "Create LVM snapshot"
if [ "$lv_name_logbin" != "$lv_name" ] ; then
	lvcreate -l $(($free_pe / 2)) -s -n dbbackupdatadir $lv_name
	lvcreate -l $(($free_pe / 2)) -s -n dbbackuplogbin $lv_name_logbin
else
	lvcreate -l $free_pe -s -n dbbackupdatadir $lv_name
fi

###
# Start server
###
echo "Start $MYSQLBINARY: ($MYSQL_START)"
$MYSQL_START &
i=0
until mysqlshow -u "$DBROOTUSER" -h "$master_hostname" -p"$DBROOTPASSWORD" > /dev/null 2>&1; do
	if [ "$i" -gt "$STOP_TIMEOUT" ] ; then
		echo ""
		echo "ERROR: Can't start MySQL server" >&2
		exit 1
	fi
	echo -n "."
	sleep 1
	i=$(($i + 1))
done
echo "OK"

###
# Mount snapshot
###

echo "Mount LVM snapshot"
SNAPSHOT_DATADIR_MOUNT="$SNAPSHOT_MOUNT_PATH/snap-dbbackupdatadir"
SNAPSHOT_LOGBIN_MOUNT="$SNAPSHOT_DATADIR_MOUNT"
mkdir -p "$SNAPSHOT_DATADIR_MOUNT"
TYPEFS_BACKUP=$(df -T "$datadir" | tail -1 | awk -F' ' '{print $(NF-5)}')
[ "$TYPEFS_BACKUP"  = "xfs" ] && MNTOPTIONS="-o nouuid"
mount $MNTOPTIONS /dev/$vg_name/dbbackupdatadir "$SNAPSHOT_DATADIR_MOUNT"
if [ "$lv_name_logbin" != "$lv_name" ] ; then
	SNAPSHOT_LOGBIN_MOUNT="$SNAPSHOT_MOUNT_PATH/snap-dbbackuplogbin"
	mkdir -p "$SNAPSHOT_LOGBIN_MOUNT"
	mount $MNTOPTIONS /dev/$vg_name/dbbackuplogbin "$SNAPSHOT_LOGBIN_MOUNT"
fi

###
# Get Index path
###

concat_datadir=$(echo "$datadir" | sed "s#^${mount_point}##")
concat_logdir=$(echo "$logbin_loc" | sed "s#^${mount_point_logbin}##")
last_index_file=$(cat "$SNAPSHOT_LOGBIN_MOUNT/$concat_logdir/${logbin_files}.index" | tail -1)
last_index_file=$(basename "$last_index_file")
#bin_log_num=$(echo "$last_index_file" | awk -F. '{ value = $NF + 1 } END { printf "%06d", value}')
binlog_pos=$($MYSQLBINLOG "$SNAPSHOT_LOGBIN_MOUNT/$concat_logdir/$last_index_file" | tail -100 | perl -e '$last_pos=""; while (<>) { if (/^#.*?\send_log_pos\s([0-9]+)/) { $last_pos = $1; } } print $last_pos . "\n";')
binlog_file=$(basename "$last_index_file")

echo "BinLog File = " $binlog_file
echo "BinLog Position = " $binlog_pos

###
# Make master DB writable
###

echo "Remove read_only on master"
mysql -f -u "$DBROOTUSER" -h "$master_hostname" -p"$DBROOTPASSWORD" -e "SET GLOBAL read_only=off"

###
# Delete from other side
###

echo "Delete Logbin and RelayLog files"
$USER_SUDO ssh $slave_hostname "rm -f \"${logbin_loc}/${logbin_files}\"* \"${relaylog_loc}/${relaylog_files}\"*"

###
# Rsync
###

echo "Rsync in progress (exclude MySQL, ${logbin_files}, ${relaylog_files})"
rsync -av --delete --progress --exclude="mysql" --exclude="${pidname}.pid" --exclude="${logbin_files}*" --exclude="${relaylog_files}*" --exclude="auto.cnf" --exclude=".ssh/*" "$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/" -e "$USER_SUDO ssh" $slave_hostname:$datadir/

mysql_ibd_system=''
for file in $(ls "$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/mysql/"*.ibd); do
    filename=$(basename $file | sed 's/\.ibd//')
    mysql_ibd_system="$mysql_ibd_system \"$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/mysql/$filename.ibd\" \"$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/mysql/$filename.frm\""
done
if [ -n "$mysql_ibd_system" ] ; then
    eval rsync -av --progress $mysql_ibd_system -e \"\$USER_SUDO ssh\" \$slave_hostname:\"\$datadir/mysql/\"
fi

# Mode Fastest. Uncomment this and comment line above
#rsync -av --delete --progress --exclude="*.MYI" --exclude="*.MYD" --exclude="mysql" --exclude="${pidname}.pid" --exclude="${logbin_files}*" --exclude="${relaylog_files}*" --exclude=".ssh/*" "$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/" -e "$USER_SUDO ssh" $slave_hostname:$datadir/
#rsync -av --size-only --delete --progress --include='*/' --exclude="mysql" --include='*.MYI' --include='*.MYD' --exclude='*' --exclude=".ssh/*" "$SNAPSHOT_DATADIR_MOUNT/$concat_datadir/" -e "ssh -i /var/lib/mysql/.ssh/id_rsa" $USER@$slave_hostname:$datadir/

###
# Suppression du snapshot
###

echo "Umount and Delete LVM snapshot"
umount "$SNAPSHOT_DATADIR_MOUNT"
lvremove -f /dev/$vg_name/dbbackupdatadir
if [ "$lv_name_logbin" != "$lv_name" ] ; then
	umount "$SNAPSHOT_LOGBIN_MOUNT"
	lvremove -f /dev/$vg_name/dbbackuplogbin
fi


###
# Demarrer le serveur slave
###

echo "Start MySQL Slave"
$USER_SUDO ssh $slave_hostname "$MYSQL_START &"
i=0
until mysqlshow -u "$DBROOTUSER" -h "$slave_hostname" -p"$DBROOTPASSWORD" > /dev/null 2>&1; do
        if [ "$i" -gt "$STOP_TIMEOUT" ] ; then
                echo ""
                echo "ERROR: Can't start MySQL server" >&2
                exit 1
        fi
        echo -n "."
        sleep 1
        i=$(($i + 1))
done
echo "OK"

###
# Demarrer la replication
###
echo "Start Replication"
mysql -f -u "$DBROOTUSER" -h "$slave_hostname" -p"$DBROOTPASSWORD" << EOF
RESET MASTER;
STOP SLAVE;
RESET SLAVE;
CHANGE MASTER TO MASTER_HOST='$master_hostname', MASTER_USER='$DBREPLUSER', MASTER_PASSWORD='$DBREPLPASSWORD', MASTER_LOG_FILE='$binlog_file', MASTER_LOG_POS=$binlog_pos;
START SLAVE;
show processlist;
quit
EOF

exit 0
