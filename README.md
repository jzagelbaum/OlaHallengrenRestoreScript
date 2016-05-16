# OlaHallengrenRestoreScript
Standby restore script output for Ola Hallengren's Maintenance Solution

There’s numerous blogs and presentations out there about Ola’s Maintenance Solution. I don’t feel a strong need to try to replicate that information here. What I am presenting is a custom extension that works out of the box for those of you that have created jobs using the maintenance solution. The scripts will add an additional job step to all DatabaseBackup jobs which will output a continuously updated text file that contains the most current restore scripts for each database in the instance.

Please note that there are three requirements for the solution to function correctly:
1.The DatabaseBackup jobs must use @LogToTable = ‘Y’
2.In order for the generated restore script to be valid, at least one full database backup should be logged to the CommandLog Table
3.SQL Server agent should have read / write access to the directory where the restore scripts will be written. The default is the @Directory value.

If you don’t know what @LogToTable, CommandLog, and @Directory are, then please read up on Maintenance Solution before continuing.

Implementation

RestoreCommand Stored Procedure

Use the same database that the Maintenance Solution objects are created in; the default is Master. First create the RestoreCommand s proc. This is the procedure that will be executed each time the DatabaseBackup jobs are run. There are no input parameters for this procedure. It reads the records from CommandLog and outputs the restore commands for each database being backed up on the instance. This includes log, diff, and full based on last completed backup and backup type. You can create the procedure and execute it to view the output as a sample:

RestoreCommandOutput

Please, please, please do not just create this procedure without implementing the job script step. The whole point of this solution is to have a standby restore script available if your instance / database becomes unusable (and you’re not clustering, etc.). I’ve really tried to make it as easy as possible to add the job step (assuming you’re using the OOTB maintenance solution created jobs). That being said…

Create Restore Script Job Steps

This script accepts two parameter values:
1.@DatabaseName, the database where the Maintenance Solution and RestoreCommand objects are located (default of Master)
2.@RestoreScriptDir, accepts ‘Backup_Dir’, ‘Error_Log’, or custom defined dir, e.g., ‘C:\’. If the dir is a custom value, the directory must be created prior to running the job.

For the @RestoreScriptDir parameter, the default value ‘Backup_Dir’ places the script in the instance level folder in the directory of the backup files, which is determined by the value of the @Directory parameter. ‘Error_Log’ places the restore script in the same dir as the default location of Maintenance Solution output files.

Make sure SQL Agent has read / write access to any custom directory if used.

After the script is run, you now have an additional job step in all of your DatabaseBackup jobs

Result

Now, each time a DatabaseBackup job is run, a continuously updated text file containing the latest restore script is written to the appropriate instance folder of the configured directory. 
So, you now have the power to restore your instance at the database level up to the last verified, completed backup. No GUI, no guesswork, and most importantly, no trying to figure out what needs to be restored when you have the least amount of time to think about it.

