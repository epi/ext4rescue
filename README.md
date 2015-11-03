ext4rescue
==========

ext4rescue is a tool for automated data recovery from ext4 file systems that
have been corrupted due to a damage of the underlying physical media.

ext4rescue works on disk image and log file produced using
[GNU ddrescue](http://www.gnu.org/software/ddrescue/).
This method is safer and more reliable than reading data directly from the
damaged media.

Usage
-----

### Invocation syntax

-   Diagnostics and recovery

        ext4rescue [OPTION]... IMAGE [DDRESCUE_LOG]

    `IMAGE` is the ext4 file system image file to recover the data from.

    `DDRESCUE_LOG` is a text file in which each line describes a block of data in the image file and contains
    the starting position of the block, the size of the block, and its status – non-tried, failed or finished.
    ext4rescue assumes that finished blocks contain correct data.
    For more details refer to the GNU ddrescue manual.

    A typical workflow is to run ddrescue first to obtain the file system image and log files,
    and then start ext4rescue with some diagnostic options, such as `--summary` or `--list=bad`.
    Once the files suitable for recovery are identified, the `--to` option is used to extract them.

    **DO NOT USE EXT4RESCUE DIRECTLY ON A DAMAGED MEDIA.**

-   Post-recovery check

        ext4rescue [OPTION]... -L bad|all [-r] [DIR]...

### Diagnostic and recovery options

-   `-s`, `--summary`

    Show collective statistics about the file system.

-   `-l`, `--list=all|bad`

    List files, ordered by inode number.

    The format of the output is:

                                     links
           inode status       mode found/all uid   gid       size name(s)
        15103149 ---l-- -rw-r--r--   1/  2  1000  1000       8984 /epi/proj/rpi-gcc/rpi-gcc/build/linux/drivers/net/wireless/ath/ath9k/wmi.c
        15103151 ---l-d -rw-r--r--   1/  2  1000  1000      64397 /epi/proj/rpi-gcc/rpi-gcc/build/linux/drivers/net/wireless/ath/ath9k/xmit.c
        15103154 -----d -rw-r--r--   2/  2  1000  1000       6291 /epi/proj/rpi-gcc/rpi-gcc/src/linux-3.2.27/drivers/net/wireless/ath/hw.c
                                                                  /epi/proj/rpi-gcc/rpi-gcc/build/linux/drivers/net/wireless/ath/hw.c
        15103158 -----d -rw-r--r--   2/  2  1000  1000      16215 /epi/proj/rpi-gcc/rpi-gcc/src/linux-3.2.27/drivers/net/wireless/ath/regd.c
                                                                  /epi/proj/rpi-gcc/rpi-gcc/build/linux/drivers/net/wireless/ath/regd.c
        18488326 -pnl-- -rw-r--r--   0/  1  1000  1000        292 ~~@UNKNOWN_PARENT/~~FILE@18488326
        18488327 -pnl-- -r--r--r--   0/  1  1000  1000       4124 ~~@UNKNOWN_PARENT/~~FILE@18488327
        18489561 ---l-d drwxr-xr-x  12/ 13  1000  1000       4096 /epi/proj/xedisk/xedisk
        18489563 --nl-- drwxr-xr-x   7/  8  1000  1000       4096 /epi/proj/xedisk/xedisk/~~DIR@18489563
        18489595 --nl-- drwxr-xr-x   1/  2  1000  1000       4096 /epi/proj/xedisk/xedisk/~~DIR@18489595
        18489608 -----d drwxr-xr-x   3/  3  1000  1000       4096 /epi/proj/cito/cito
        18489609 --nl-- drwxr-xr-x   7/  8  1000  1000       4096 /epi/proj/cito/cito/~~DIR@18489609
        18497537 i----- d            2                            /epi/proj/xedisk/oldxedisk/.git/objects/dc
        18497544 i----- d            2                            /epi/proj/xedisk/xedisk/~~DIR@18489563/objects/90
        23864074 ----md -rw-r--r--   1/  1  1000  1000   61655040 /epi/Videos/demos/sonolumineszenz.avi
        23993787 -----d -rw-------   1/  1  1000  1000        225 /epi/agh/mgr/xilinx/mb1/mb.cmd_log
        23993810 -----d -rw-------   1/  1  1000  1000        115 /epi/agh/mgr/xilinx/uboot_linux/cpu/etc/download.cmd

    If some data or metadata about a file have been lost, it will be reflected by one or more letters
    in the status column.
    The meaning of the status letters is:

    -   `i` – the inode is not readable. This happens if there are valid links (directory entries) to the inode,
        but the inode itself is damaged. In such case, the file data cannot be recovered because ext4rescue
        does not know their location.

    -   `p` – the parent directory is not known. For regular files and symbolic links this means that no links
        pointing to this file's inode have been found, because its parent directory could not be read.
        For a directory, it also means that no subdirectories of it have been found.

    -   `n` – the name of the file is not known. Just like `p`, this happens when no links
        pointing to this file's inode have been found.
        A surrogate name is created for such files based on the file type and inode number, e.g. `~~DIR@18489609`.

    -   `l` – some or all links to the file could not be found.

    -   `m` – the extent tree is partially or entirely damaged.

    -   `d` – the file contents are partially or entirely damaged.

-   `-t DIR`, `--to=DIR`

    Extract the files from the file system image to directory `DIR`.
    By default, all files are extracted. The selection of files to extract can be narrowed using the `--from` option.
    Files with errors will have the extended attribute `user.ext4rescue.status` set.
    It can be examined later by using *getfattr(1)* for each file or, more conveniently, using the
    `--list-extracted` option (see below).
    The format and meaning of the attribute value is the same as in the status column in the output of `--list`.

-   `-f PATH`, `--from=PATH`

    Extract files only from the specified `PATH` in the file system image.
    If `PATH` points to a directory, it is extracted recursively.
    This option can be specified multiple times.

-   `-c`, `--chown`

    Set user ID and group ID on extracted files. Additional privileges are required for that to succeed,
    see *chown(2)*.

-   `-F --force-scan`

    This option forces ext4rescue to re-analyze the file system image even if a cached analysis result is present.
    See more information about caching [below](#cache).

### Post-recovery checks

-   `-L all|bad`, `--list-extracted=all|bad`

    Examine the status of the files after the recovery. This option prints the value of the extended
    attribute `user.ext4rescue.status` for all files in the specified `DIR`s (or in the current directory,
    if no `DIR` is specified).

-   `-r`, `--recursive`

    Used with `-L` lists subdirectories recursively.

Technical details
-----------------

### How it works

The ext4 file system stores not only the contents of your files, but also some
metadata which define file attributes and location of the data in the directory
structure and on the disk partition. For a file to be completely recovered,
its directory entry, its inode and the map of data blocks must be correctly
read before the actual file data can be accessed.

If the inode or the whole block map is damaged, there is no way to determine
the location of the data on disk, hence no data can be recovered.
If the inode is correct and the block map suffers only a partial damage or
the block map is also correct but some data blocks cannot be read, the data
can be partially recovered but in most cases they will be useless. However,
some multimedia formats allow replaying partially damaged files, compressed
archives can often be uncompressed up to the point of the first damage (.tar.gz)
or repaired (.zip), etc.
Therefore, ext4rescue tries to recover also these files.

Directory entries are required only to determine the names of the files and
their location within the directory structure. It is possible that the contents
of a file can be fully recovered even though its name is not known.

### <a name="cache" />Caching analysis results

Since it usually takes several minutes to complete the analysis of a large file system, the analysis results are
cached. The next time ext4rescue is invoked with the same file system image and ddrescue log file, it restores
all information about the status of the files from the cache, reducing the start-up time to just a few seconds.

This is safe as long as the contents of the image and the log file are not changed between runs.
ext4rescue checks also if the modification times of both files are the same as for the cached versions,
but if the files were changed (e.g. by using ddrescue again in the hope of recovering data from a few
more bad sectors) and ext4rescue still uses the old cache, it can be forced to re-analyze the image by using
the `-F` or `--force-scan` option.

Cache files are stored in the user's home directory, under *$HOME/.ext4rescue/*.
You can safely remove this directory at any time.

History
-------

- v0.1.0 (2015-11-??) - first release

Bugs and limitations
--------------------

Listed in the order of decreasing priority:

- Currently only ext4 extent trees are supported. Support for legacy block maps is planned for future releases.
- Many flags in the super block are ignored.
- Master super block is always used – there is no option to use any of its copies.
- Sub-second part of last access time and last modification time is discarded when extracting files.
- There is no way to map the user and group IDs in the source file system to different ones in the target file system.
- An option to display detailed information about a file (stat + location of data + detailed damage report)
  would be useful.
- Only directories, regular files and symbolic links are recovered, other file types (such as device nodes)
  are skipped silently.
- Change time and creation time are not preserved.
- ext4rescue optimistically assumes that the regions of the disk image marked readable by *ddrescue(1)*
  are correct, which may be true if the drive only has some bad sectors, and you did not attempt to mount it
  writable. Errors not logged in the ddrescue log file may make ext4rescue unable to
  analyze the file system or recover the data, or may result in files containing wrong data being reported as
  recovered correctly.

License
-------

`ext4rescue` is published under the terms of the GNU General Public License,
version 3. See the file `COPYING` for more information.
