#!/bin/bash

###################################################
# Centreon                                Juin 2017
#
# Bascule le slave en master
#
###################################################

. /usr/share/centreon-ha/lib/mysql-functions.sh
. /etc/centreon-ha/mysql-resources.sh

usage()
{
echo
echo "Use : $0 [<db hostname>]"
echo
}

cmd_line()
{
if [ $# -gt 1 ]
then
        usage
        exit 1
fi

PARAM_DBHOSTNAME=$1
}

slave_reset()
{
	# Verification des threads:
	mysql -f -u "$DBROOTUSER" -h "$PARAM_DBHOSTNAME" "-p$DBROOTPASSWORD" -e 'SHOW SLAVE STATUS\G' | grep -qi 'Slave_IO_Running: No'
	ret_value1=$?
	mysql -f -u "$DBROOTUSER" -h "$PARAM_DBHOSTNAME" "-p$DBROOTPASSWORD" -e 'SHOW SLAVE STATUS\G' | grep -qi 'Slave_SQL_Running: No'
	ret_value2=$?
	if [ "$ret_value1" -eq 0 ] && [ "$ret_value1" -eq 0 ] ; then
		echo "Slave Threads already stopped."
		return 0
	fi

	echo "Stop I/O Thread - Connection stopped with the master"
        mysql -f -u "$DBROOTUSER" -h "$PARAM_DBHOSTNAME" "-p$DBROOTPASSWORD" << EOF
RESET MASTER;
STOP SLAVE IO_THREAD;
quit
EOF
	# On attend que le thread SQL finisse de traiter le relay-log
	# Has read all relay log; waiting for the slave I/O thread to update it
	# http://dev.mysql.com/doc/refman/5.0/en/slave-sql-thread-states.html
	TIMEOUT=60
	echo "Waiting Relay log bin to finish proceed (TIMEOUT = ${TIMEOUT}sec)"
	i=0
	while : ; do
		if [ "$i" -gt "$TIMEOUT" ] ; then
			echo "Not finished smoothly.!!!"
			break
		fi
		mysql -f -u "$DBROOTUSER" -h "$PARAM_DBHOSTNAME" "-p$DBROOTPASSWORD" -e 'SHOW PROCESSLIST\G' | grep -qi 'Has read all relay log; waiting for the slave I/O thread to update it'
		if [ "$?" -eq "0" ] ; then
			break
		else
			echo -n "."
		fi
		i=$(($i + 1))
		sleep 1
	done

	# On attend qu'il finisse de lire les relay
        mysql -f -u "$DBROOTUSER" -h "$PARAM_DBHOSTNAME" "-p$DBROOTPASSWORD" << EOF
STOP SLAVE SQL_THREAD;
RESET SLAVE;
RESET MASTER;
CHANGE MASTER TO MASTER_HOST='';
SET GLOBAL read_only = OFF;
quit
EOF
}

#
# Main
#
cmd_line $*

# Initialisation du slave
slave_reset
