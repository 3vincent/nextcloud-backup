#!/bin/bash
#
# nextcloud backup script
#
### SETUP AREA
###

backupDestination=/home/USERDIR
nextcloudInstallation=/var/www/nextcloud
nextcloudData=/opt/nextcloud-data
apacheUser=www-data
mysqlUser=nxtclouddb
mysqlDatabase=nxtclouddb
mysqlPassword=''
TMP_PATH=/tmp

###
### END SETUP AREA

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# 1. Activate Maintenance Mode
# 2. Backup MySQL Database
# 3. Backup Data Dir
# 4. Backup Installation Dir in Apache Web Folder
# 5. Deactivate Maintenance Mode
# 6. Size, Location and Info-Output
#
#    Source mainly: https://www.c-rieger.de/nextcloud-sicherung-und-wiederherstellung/
#
#
#    Script does not check for available free space on the drive!
#    Have Fun
#
#    From remote do something like this:
#    $ scp -rp ${server-ip}:{source_dir_on_server} {destination_dir_on_local}
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# if any errors quit
set -e

# set nextcloud maintenance mode on or off function
nextcloudMaintananceSetMode() {
  modeSet="${1}"

  if [ "$modeSet" != "on" ] && [ "$modeSet" != "off" ]; then
    echo "*** Error: Mode must be either on or off!"
    echo "exiting..."
    exit 1;
  fi

  echo "Turn Nextcloud Maintenance Mode: ${modeSet}"
  sudo -u $apacheUser $nextcloudInstallation/occ maintenance:mode --"${modeSet}"
  # if previous command ended without error
  if [ "$?" -eq "0" ]; then
    echo "....Done"
  else
    echo "*** Error setting maintenance mode to ${modeSet}"
    echo "*** exiting..."
    exit;
  fi
}

### 0. Preparations
###

## Check if root

if [ "$EUID" -ne 0 ]
  then echo "***error *** Please run as root"
  exit
fi

## check if cli tool exist on the system

declare -a CLI_TOOLS

CLI_TOOLS=(
  "pv"
  "tar"
  "gzip"
  "du"
  "mysqldump"
)

for tool in "${CLI_TOOLS[@]}"
do
  if [ ! "$(which "$tool")" ]; then
    echo "***error *** $tool does not exist on this system. Please install it! Exiting..."
    exit
  fi
done

# check if the environment variable for the mysql Password is set
# if not use the password that was set in the variable
# env var password is always preferred to the one set inside the file

if [ -z "$NEXTCLOUDMYSQLPW" ] && [ -z "$mysqlPassword" ]
then
  echo "no mysql password set"
  echo "exiting..."
  exit
fi

if [ -n "$NEXTCLOUDMYSQLPW" ]
then
  mysqlPassword=$NEXTCLOUDMYSQLPW
fi

if [ -z "$NEXTCLOUDMYSQLPW" ] && [ -n "$mysqlPassword" ]
then
  echo "Using mySQL Password that was set in the file"
fi

# fetch current date as YYYYMMDD
DATESTAMP() { date +%Y-%m-%d_%H-%M-%S; }

# Create Backup Directory TARGET
backupDestination="$backupDestination/nextcloud_backup_$(DATESTAMP)"

if [ -d "$backupDestination" ]; then
  echo "*** error*** Directory: $backupDestination already exists!"
  exit
fi

mkdir "$backupDestination"

echo "############## Nextcloud Backup 101 ##############"

### 1. Activate Maintenance Mode in nextcloud
###

if (nextcloudMaintananceModeOn); then
  echo "..okay"
	echo ""
else
  echo "***error *** Nextcloud occ Maintenance Mode was not successfull!"
  exit
fi

### 2. MySQL Backup
###

# check if destination really exists

if [ ! -d "$backupDestination" ]; then
  echo "***error *** Directory does not exist: $backupDestination"
  nextcloudMaintananceModeOff
  exit 1
fi

# write mysql config file that is used to hide the password from the process list

mysqlConfigFile=${TMP_PATH}/.mylogin.cnf

printf "[mysqldump]\nuser=%s\npassword=%s\n" "${mysqlUser}" "${mysqlPassword}" > $mysqlConfigFile

chmod 600 ${mysqlConfigFile}

# prepare backup

echo "Creating Backup of MySQL Database $mysqlDatabase ..."
FIXEDDATESTAMP=$(DATESTAMP)
mysqldump --defaults-file=${mysqlConfigFile} \
  --single-transaction \
  -h localhost $mysqlDatabase > ${TMP_PATH}/"${FIXEDDATESTAMP}"_nextcloud_db_backup_tempfile.sql
echo "...compressing database dump"
gzip < ${TMP_PATH}/"${FIXEDDATESTAMP}"_nextcloud_db_backup_tempfile.sql > "$backupDestination/${FIXEDDATESTAMP}_nextcloud_mysqlDatabase.sql.gz"
rm ${TMP_PATH}/"${FIXEDDATESTAMP}"_nextcloud_db_backup_tempfile.sql
rm ${mysqlConfigFile}

echo "...okay"
echo ""

### 3. Backup Data Directory
###

if [ ! -d "$backupDestination" ]; then
  echo "***error *** Directory not found: $backupDestination"
  nextcloudMaintananceModeOff
  exit 1
fi

if [ ! -d "$nextcloudInstallation" ]; then
  echo "***error *** Directory not found: $nextcloudInstallation"
  nextcloudMaintananceModeOff
  exit 1
fi

if [ -d "$backupDestination" ] && [ -d "$nextcloudData" ]; then
  echo "Creating Backup of Data Directory $nextcloudData ..."
  sizeOfDir=$(du -sk "$nextcloudData" | cut -f 1)
  tar -cpf - -C "$nextcloudData" . \
    | pv --size "${sizeOfDir}"k -p --timer --rate --bytes \
    | gzip -c > "$backupDestination/$(DATESTAMP)_nextcloud-DataDir.tar.gz"
fi

echo "...okay"
echo ""

### 4. Backup installation directories and files and move to backupDestination
###

# set default size to zero for counting the 
# size of the nextcloud installation directory
sizeOfDir=0 

if [ ! -d "$backupDestination" ]; then
  echo "***error *** Directory not found: $backupDestination"
  nextcloudMaintananceModeOff
  exit 1
fi

if [ ! -d "$nextcloudInstallation" ]; then
  echo "***error *** Directory not found: $nextcloudInstallation"
  nextcloudMaintananceModeOff
  exit 1
fi

if [ -d "$backupDestination" ] && [ -d "$nextcloudInstallation" ]; then
  echo "Creating Backup of Installation Directory $nextcloudInstallation ..."
  sizeOfDir=$(du -sk "$nextcloudInstallation" | cut -f 1)
  tar -cpf - -C "$nextcloudInstallation" . \
    | pv --size "${sizeOfDir}"k -p --timer --rate --bytes \
    | gzip -c > "$backupDestination/$(DATESTAMP)_nextcloud-InstallationDir.tar.gz"
fi

echo "...okay"
echo ""

### 5. Deactivate Maintenance Mode
###

if (nextcloudMaintananceModeOff); then
  echo "...okay"
else
  echo "***error *** Something went wrong with turning nextcloud maintenance mode off"
fi

### 6. Size, Location, Infomation Output
###

backupSize=$(du -csh "$backupDestination" | grep total | awk '{ print $1 }')
echo ""
echo "Done."
echo "Your Backup Information:"
echo "Location:      $backupDestination"
echo "Size:          $backupSize"
