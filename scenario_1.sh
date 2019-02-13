#!/bin/bash
shopt -s expand_aliases
source ~/.bash_aliases

#Constants  for  this job: old_rds_identifier,old_rds_read_identifier. If disaster recovery is needed on another production RDS, change these constants below along with the other constants if needed.
#Parameters: SECURITY_GROUP_ID =(sg-0a95b05dfcef42f38), CIDR =(10.120.0.117/32), RESTORE_TIME =(2019-02-12T02:00:00Z), DB_SUBNET_GROUP_NAME =(kube-eztrans-prod-rds),  

old_rds_identifier='perf-testing-eztrans-prod'
old_rds_read_identifier='perf-testing-eztrans-prod-readrep'
temp_rds_identifier='pitr-perf-testing-eztrans-prod'
temp_rds_read_identifier='pitr-perf-testing-eztrans-prod-readrep'

#The following identifiers must begin with a letter; must contain only ASCII letters, digits, and hyphens; and must not end with a hyphen or contain two consecutive hyphens
final_old_rds_snapshot='final-old-rds-master-snapshot'
final_old_rds_read_snapshot='final-old-rds-read-snapshot'

#printf "Enter passcode to run this job:\n"
#read PASSCODE
#if [ echo -n "$PASSCODE" | md5sum != "51592392cce165ea2088d5d865ac5df1  -" ]; then
#printf "Incorrect passcode."

printf "Job started.\n\n"
printf "Enter VPC security group ID of the master instance:\n"
read SECURITY_GROUP_ID
printf "Enter CIDR of the rule that you want to temporarily revoke from security group - $SECURITY_GROUP_ID\n"
read CIDR
printf "Enter Restore time(UTC) in the format \"2019-02-12T02:00:00Z\"\n"
read RESTORE_TIME
printf "Enter DB subnet group name of the master instance:\n"
read DB_SUBNET_GROUP_NAME

#Stop replication. 
rds_perf_read -e "call mysql.rds_stop_replication()";
date
printf "Replication stopping... ETA: < 5s\n\n"

#Need to stop incoming traffic to master RDS or database that is hit(For VPC security Groups use the SecurityGroupId and not the SecurityGroupName)
#What if there are multiple security group id's to be revoked?
aws ec2 revoke-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 3306 --cidr "$CIDR"
date
printf "Incoming traffic to database stopping... ETA: < 5s\n\n"

#Restore master to point-in-time. The time specified is in UTC. Took around 12 minutes on perf-testing(db.m4.large) rds.
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$old_rds_identifier" --target-db-instance-identifier "$temp_rds_identifier" --restore-time "$RESTORE_TIME" --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --vpc-security-group-ids "$SECURITY_GROUP_ID" --no-multi-az --deletion-protection 
date
printf "Master restoring to point in time(UTC) $RESTORE_TIME with subnet group $DB_SUBNET_GROUP_NAME... ETA: < 20m\n\n"

aws rds wait db-instance-available --db-instance-identifier "$temp_rds_identifier"
# while [ true ]; do
# printf "Disable deletion-protection on old master for deleting?(y/n)\n"
# read flag
# if [ "$flag" = "y" ]; then
# break	
# else
# continue;
# fi
# done

#Disable deletion-protection on old master
aws rds modify-db-instance --db-instance-identifier "$old_rds_identifier" --no-deletion-protection
date
printf "Deletion-protection on old master disabling... ETA: < 15s\n\n"

#Delete old master
aws rds delete-db-instance --db-instance-identifier "$old_rds_identifier" --final-db-snapshot-identifier $final_old_rds_snapshot	
date
printf "Old master deleting and snapshot creating... ETA: < 15m\n\n"

aws rds wait db-instance-deleted --db-instance-identifier "$old_rds_identifier"
# while [ true ]; do
# printf "Rename new master instance?(y/n)\n"
# read flag
# if [ "$flag" = "y" ]; then
# break	
# else
# continue;
# fi
# done

#Rename new master instance(It should take less than 2 minutes for this renaming)
aws rds modify-db-instance --db-instance-identifier "$temp_rds_identifier" --new-db-instance-identifier "$old_rds_identifier" --apply-immediately
date
printf "Master instance being renamed to $old_rds_identifier... ETA < 2m\n\n"

#aws rds wait db-instance-available --db-instance-identifier "old_rds_identifier"
while [ true ]; do
printf "Authorize incoming traffic to master RDS(Check if rename is complete in the AWS management console)?(y/n)\n"
read flag
if [ "$flag" = "y" ]; then
break	
else
continue;
fi
done

#Authorize incoming traffic to master RDS
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 3306 --cidr $CIDR
date
printf "Incoming traffic to database resuming... ETA < 5s\n\n"

#Disable deletion-protection on old read replica
aws rds modify-db-instance --db-instance-identifier "$old_rds_read_identifier" --no-deletion-protection
date
printf "Disabling deletion-protection on old read replica... ETA: < 15s\n\n"

#Delete old read replica so that the new one can be named. Took around 8 minutes
aws rds delete-db-instance --db-instance-identifier "$old_rds_read_identifier" --final-db-snapshot-identifier "$final_old_rds_read_snapshot"
date
printf "Deleting old read replica and creating final snapshot... ETA: < 15m\n\n"

# while [ true ]; do
# printf "Create read replica of new master RDS with the same name as that of the old replica?(yes/no)\n"
# read flag
# if [ "$flag" = "yes" ]; then
# break	
# else
# continue;
# fi
# done

aws rds wait db-instance-deleted --db-instance-identifier "$old_rds_read_identifier"

#Create read replica of new master instance
aws rds create-db-instance-read-replica --db-instance-identifier "$old_rds_read_identifier" --source-db-instance-identifier "$old_rds_identifier" --deletion-protection
date
printf "Creating new read replica... ETA: < 20m"

date
printf "Job finished."
