# getmyfiles
Shell and Python tools to retrieve files from a cluster's nodes to $HOME

This tool allows the user to retrieve files and move them to the user's home 
directory. While it will work in any environment that uses IP addressing, the 
intent is to use it primarily with clusters.

There are a couple of assumptions that users must keep in mind.

- It only works with your own files.
- It does not copy the files, it moves them from the place where they are now to the directory you specify.
- As a user, you must have ssh-key authentication to avoid constantly being asked for your password.
- While you *could* move files within the same local file system, that's a pointless activity.
- The common Linux tools -- `rsync`, `tar`, `gzip`, *etc* -- must be present.
- This tool ignores in the information in `$HOME/.ssh/config` to ensure consistent behavior.

# command line use

The general syntax is the customary Linux tool standard.

```bash
getmyfiles --host remotelocation --dest directory --unpack
```

Here is the meaning and format of the parameters.

- `--host remotelocation` : `remotelocation` can be an IP address or a hostname, with the assumption that the remote user name is the same as the user currently running the program.
- `--dest directory` : If `directory` is just a bare name like "logs", it is assumed to be in `$HOME`. You can name any directory you like, and you will need write access to it.
- `--unpack` : If present, the directory structure from the remote location is "cloned" into the destination. If not, the directory will contain a gzipped tarball whose fate you can decide.
