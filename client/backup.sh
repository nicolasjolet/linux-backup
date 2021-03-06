#!/bin/bash

##---- USER VARIABLES
. $(dirname $0)/backup.cfg

##---- SCRIPT VARIABLES
BACKUP_TIME="$(date +'%Y%m%d-%H%M')"
LOG_FILE=/tmp/dW5pcXVlaWRmb3JiYWNrdXAt-backup.log

##---- FUNCTIONS

save_pipe_status() {
	_saved_pipe_status=( "${PIPESTATUS[@]}" )
}

#1: (optional) index of command to check exit status. If ommited, all command exit status are tested
is_error_in_last_cmd() {	
	local e
	
	if [[ $# -ne 0 ]]; then 					# if any arguments passed
		if [[ $1 -lt ${#_saved_pipe_status[@]} ]]; then	# if index inside array boundaries
			[[ ${_saved_pipe_status[$1]} -ne 0 ]]
		else
			false 								# if index greater than array boundaries, return false
		fi
		return
	fi
	
	# if no arguments passed, check all exit codes
	for e in "${_saved_pipe_status[@]}"; do
		[[ ! $e -eq 0 ]] && return 0
	done
	return 1
}

error_exist_in_log() {
	[[ $(grep -ci 'ERROR' $LOG_FILE) -ne 0 ]]
}

add_to_log() {
	function _add_to_log() {
		if [[ $# -eq 0 ]]; then
			return
		fi

		if [[ $SHOW_LOG_IN_CONSOLE -eq 1 ]]; then
			echo $(date) " -- " $* | tee -a $LOG_FILE
		else
			echo $(date) " -- " $* >> $LOG_FILE
		fi
	}
	
	local t
	
	if [[ $# -eq 0 ]]; then # function has been piped
		while read t; do
			_add_to_log $t
		done
    else	
        _add_to_log $*
    fi
}

echo_err() {
	echo $* >&2
}

send_mail() {
	echo "$2" | mutt -e "my_hdr Content-Type: text/html" -s "$1" -- ${MAIL_TO}
}

ssh_execute() {
	ssh -i "/root/.ssh/id_rsa" -o StrictHostKeyChecking=no ${REMOTE_BACKUP_USER}@${BACKUP_HOST} "$1"
}

#1: path to file to delete
ssh_rm() {
	ssh_execute "rm -f '$1'"
}

#1: path to remote file to pipe into
#	if the file exists, it will be overriden
ssh_remote_cat() {
	ssh_execute "cat - > '$1'"
}

save_mysql() {	
	echo "Creating mysql dump and send it to the backup server"
	
	mysql_file_name=${BACKUP_TIME}--mysql.gz
	
	mysqldump -u "${MYSQL_USER}" --events --ignore-table=mysql.event --all-databases | gzip | ssh_remote_cat "$REMOTE_BACKUP_DIR/$mysql_file_name"
	save_pipe_status		
	
	is_error_in_last_cmd 0 && echo_err "Error while dumping mysql"
	is_error_in_last_cmd 1 && echo_err "Error while zipping dump"
	is_error_in_last_cmd 2 && echo_err "Error while sending zip on backup server"
	
	# delete remote backup on error
	if is_error_in_last_cmd; then
		echo "Pipestatus: ${_saved_pipe_status[*]}"
		echo "Delete corrupted backup on server"
		ssh_rm "$REMOTE_BACKUP_DIR/$mysql_file_name"
	fi
} 

#1: path to save
save_directory() {	
	local backup_file="$REMOTE_BACKUP_DIR/${BACKUP_TIME}--$(basename $1).tar.gz" 
	echo "Saving folder: $1"
	tar --absolute-names -zc "$1" | ssh_remote_cat "$backup_file"
	save_pipe_status
	
	is_error_in_last_cmd 0 && echo_err "Error while zipping $1"
	is_error_in_last_cmd 1 && echo_err "Error while sending zip on backup server"
	is_error_in_last_cmd && echo "Pipestatus: ${_saved_pipe_status[*]}"
	
	# delete remote backup on error
	if is_error_in_last_cmd; then
		echo "Pipestatus: ${_saved_pipe_status[*]}"
		echo "Delete corrupted backup on server"
		ssh_rm "$backup_file"
	fi
}
	
generate_mail_body() {
	echo "-------------- LOG --------------"
	cat $LOG_FILE
}

create_remote_d2d_repo() {
	ssh_execute "mkdir -p ${REMOTE_BACKUP_DIR}"
	ssh_execute "chmod -R 660 ${REMOTE_BACKUP_DIR}"
	ssh_execute "chmod 770 ${REMOTE_BACKUP_DIR}"
}

main() {
	# reset or create log file
	: > $LOG_FILE

	{
		echo "Backup started"	
		
		create_remote_d2d_repo
		
		# save mysql DBs unless user is empty
		[[ -z $MYSQL_USER ]] || save_mysql

		for f in "${FOLDERS_TO_BACKUP[@]}"; do
			save_directory "$f"
		done
		
		echo "Backup end"
	} |& add_to_log
	
	if error_exist_in_log; then
		# if errors => send email
		add_to_log "Error in log => sending email"
		send_mail "ovh-predict-prod -- BACKUP ERROR" "$(generate_mail_body)"
	else
		# do not delete log if any errors
		rm $LOG_FILE
	fi
}

main
