# windows_file_tracker
Windows Folder File Tracker

## Use Case

Assume you and a few teammates are working on files in a directory, and you want to keep track of files:

- Newly added files
- Files that are removed
- Files that are moved

This PowerShell script frequently gets the list of files in the provided folders, checks the hash of the files, and verifies if they are new or moved. Also, check for the removed files

## Features

- stores the structure of the files whenever anything gets changed
- logs the changes on screen and in the logs
- logs a few parameters of the file: Owner, Created, Last Modified
- does not compute the hash if the parameters remain the same
-