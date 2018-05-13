#!/bin/bash

# -----------------------------------------------------------------------
#  Purpose:
#  Modify an Ubuntu system for running data-to-compute example on SLURM
#  
#  Prerequisite : iRODS server should already be installed on the system
#
#  This script installs the following software services:
#
#  MUNGE =  Service for creating and validating credentials
#             (a requirement for running SLURM)
#
#  SLURM =  "Simple Linux Utility for Resource Management"
#             (a popular job scheduler and resource manager)
#
# ------------------------------------------------------------------------

SLURM_ADMIN=/var/lib/slurm
IRODS_MSIEXEC=~irods/msiExecCmd_bin

# Import symbolic error codes

DIR=$(dirname "$0")
. "$DIR/errors.rc"

add_error BAD_OPTION      "Error in program option or argument"			# 1
add_error NO_IRODS_USER   "No irods user (please install iRODS software)"	# 2
add_error MUNGE_BUILD     "munge did not build, can't continue"			# 3
add_error MUNGE_KEY       "could not create munge key file"	                # 4
add_error MUNGED_START    "could not start munge daemon"			# 5
add_error MUNGED_PERSIST  "could not install munge daemon in start scripts"	# 6
add_error SLURM_BUILD     "SLURM build (or install) failed"			# 7
add_error SLURM_CONFIG    "SLURM could not be configured"			# 8
add_error SLURM_START     "SLURM could not be started"				# 9
add_error SLURM_PERSIST   "Could not install SLURM daemons in start scripts"	# 10

# -- Check for irods service account, die unless it exists

grep '^irods:' /etc/passwd >/dev/null 2>&1 || die NO_IRODS_USER

# =-=-=-=-=-=-=
# Build and install from this directory:

mkdir -p ~/github

# Use wget to download these sources, then build and install:
#    -  http://github.com/dun/munge/archive/munge-0.5.13.tar.gz
#    -  http://github.com/SchedMD/slurm/archive/slurm-17-11-4-1.tar.gz

WGET=1

# Dictionaries to hold repository path and preferred version info

typeset -A \
  dlPath=( [munge]="dun/munge" [slurm]="SchedMD/slurm" )\
  dlTag=(  [munge]="munge-0.5.13" [slurm]="slurm-17-11-4-1" )

# -- Helper function to download software --

download() {
  local pkg="$1" 
  [ -z "$pkg" ] && exit 125
  [ -d ".old.$pkg" ] && rm -fr ".old.$pkg"/
  [ -d "$pkg" ] && mv "$pkg"/ ".old.$pkg"/
  local fname
  if [ "$WGET" = "1" ] ; then
    fname=${dlTag[$pkg]}.tar.gz
    wget "http://github.com/${dlPath[$pkg]}/archive/$fname" >/dev/null 2>&1 &&\
    tar xf $fname && mv "$pkg"-*/ "$pkg"
  else
    git clone "http://github.com/${dlPath[$pkg]}"
  fi
}

# -------------------------------------------
#  Component parts of the software install
# -------------------------------------------

f_munge_build () {

  # -- Download and build the MUNGE software

  (
    cd ~/github && \
    download munge && \
    cd munge && \
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var && \
    make && \
    sudo make install 
  ) && \
  sudo cp "$DIR"/munge.upstart /etc/init.d/munge && \
  sudo chmod 755 /etc/init.d/munge

  [ $? -eq 0 ] || warn MUNGE_BUILD
}

# -------------------------------------------

f_munge_key_install () {

  echo >&2 "Setting up munge key"
  sudo dd if=/dev/urandom of=/etc/munge/munge.key  bs=1k count=1  && \
  sudo chmod 600 /etc/munge/munge.key 
  [ $? -eq 0 ] || warn MUNGE_KEY
}

# -------------------------------------------

f_munge_start () {

  # -- Start the munge daemon

  sudo /etc/init.d/munge start
  echo -n "starting 'munge' daemon ..." >&2
  sleep 2 ; echo >&2
  [ $? -eq 0 ] || warn MUNGED_START
}


# -------------------------------------------


f_munge_daemon_persist ()
{

  # -- Make sure the links in /etc/rc*.d/ exist to start munged
  #    on reboot

  if pgrep munged  2>/dev/null >&2
  then
    ## TODO : Ub16 runlevel mgt
    true # sudo update-rc.d munge defaults
  fi
  [ $? -eq 0 ] || warn MUNGED_PERSIST
}


# -------------------------------------------

f_slurm_build_install () {
 
  # -- Build and install the SLURM software

  # bash sub-shell to preserve CWD
  (
    cd ~/github && \
    download slurm && \
    cd slurm && \
    ./configure --with-munge=/usr && \
    make -j3 && \
    make check && \
    sudo make install
  )
  [ $? -eq 0 ] || warn SLURM_BUILD
}

# -------------------------------------------

copy_scripts_ ()
{
  local TYPE DEST BASE
  case $1 in 
    epilog)
	TYPE=$1;;
    prolog)
	TYPE=$1;;
    *)
		echo >&2 "----------------------------------------------------------------------"
		echo >&2 "At this time only SLURM 'prolog' and 'epilog' scripts can be installed" 
		return ;;
  esac

  sudo dd of="$SLURM_ADMIN/root_$TYPE" <<-EOF 2>/dev/null
	#!/bin/bash
	IRODS_HOOK="$IRODS_MSIEXEC"/slurm_$TYPE
	if [ -x "\$IRODS_HOOK" ]; then
	  su irods -c "\$IRODS_HOOK"
	fi
	EOF
  # ^---last 3 lines must begin with tab characters

  sudo chmod a+rx "$SLURM_ADMIN/root_$TYPE"

  BASE="slurm_$TYPE"
  DEST="$IRODS_MSIEXEC/$BASE"
  sudo su irods -c "touch '$DEST'"
  [ -f "$DIR"/"$BASE" ] && sudo cp "$DIR"/"$BASE" "$DEST"  # -- Copy from this folder into irods
  [ -f "$DEST" ]	&& sudo chmod go+rx,u+rwx "$DEST"  # msiExec dir & enable execution      
}

f_slurm_config ()
{
  # -- Generate the SLURM config file, /usr/local/etc/slurm.conf

  sudo env -i $(/usr/local/sbin/slurmd -C) \
                SLURM_HOOK_DIR=$SLURM_ADMIN \
                perl -pe 's/\$(\w+)/$ENV{$1}/ge unless /^\s*#/' \
                < "$DIR"/slurm.conf.template                    \
                > /tmp/slurm.conf  && \
  sudo cp /tmp/slurm.conf /usr/local/etc && \
  sudo mkdir -p /var/spool/slurm{d,state} && \
  sudo chmod -R 755 /var/spool/slurm{d,state} && \
  sudo mkdir -p $SLURM_ADMIN  && \
  copy_scripts_ prolog && \
  copy_scripts_ epilog 
  [ $? -eq 0 ] || warn SLURM_CONFIG
}

# -------------------------------------------

f_slurm_persist ()
{
  if [ -f /etc/init.d/slurm ] ; then
    sudo mv /etc/init.d/slurm{,.old} 
  fi
  sudo cp "$DIR"/slurm.upstart /etc/init.d/slurm
  sudo chmod go=rx,u=rwx /etc/init.d/slurm

  if sudo /etc/init.d/slurm start ; then
    :
  else
    warn SLURM_START
    return
  fi

  if [ $? -eq 0 ] ; then 
    ## TODO : Ub16 runlevel mgt
    #sudo update-rc.d slurm defaults
    true
  else
    warn SLURM_PERSIST
  fi
}

# -------------------------------------------

menu() { echo >&2 \
"Menu:	1 f_munge_build       
	2 f_munge_key_install   
	3 f_munge_start          
	4 f_munge_daemon_persist 
	5 f_slurm_build_install  
	6 f_slurm_config         
	7 f_slurm_persist
	Q quit "
}

#======================== Main part of the script ========================

if [ $# -eq 0 ] ; then  

  #-- Automatic run-through of all install stages

  f_munge_build           || exit $?

  f_munge_key_install    || exit $?

  f_munge_start           || exit $?

  f_munge_daemon_persist  || exit $?

  f_slurm_build_install   || exit $?

  f_slurm_config          || exit $?

  f_slurm_persist         || exit $?        

else

  #-- Interactive / Menu driven

  x="."
  if [[ $1 =~ [0-9]+ ]]
  then
    x=$1
  else
    [ -n "$1" ] && menu
  fi

  while [ -n "$x" ] || read -p "->" x
  do
    case $x in 
	1) f_munge_build	  ;;
	2) f_munge_key_install    ;;
	3) f_munge_start          ;;
	4) f_munge_daemon_persist ;;
	5) f_slurm_build_install  ;;
	6) f_slurm_config         ;;
	7) f_slurm_persist        ;;
	[Qq]*) exit 0		  ;;
	*) menu ;;
    esac
    echo "Done.  Choice ($x) finished with status: $?" >&2
    x=""
  done
fi
