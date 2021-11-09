# psync

Scan a directory for image files and put them at a new location, with 
subdirectories and filenames representing the date and time
for when the files was created.

```
usage:
  psync.pl [-h, -q, -d, --mv] SOURCE DESTINATION

  Optional arguments:
    -h, --help     Show this message and exit
    -q, --quiet    Don't print information to terminal
    -d, --dry-run  Don't actually copy/move files, just print
                   (unless --quiet is set)
    --mv           Move instead of copy files from SOURCE
                   to DESTINATION

  Positional arguments:
    SOURCE       Directory to search for images and videos
    TARGET       Directory to where files will be copied to

Psync obtain timestamps from file metadata and copies files to
the destination within folders and with names corresponding to
the timestamps of the files. Files are hashed to ensure that 
only unique files are copied.
```


