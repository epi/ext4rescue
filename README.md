ext4rescue
==========

ext4rescue is a tool for automated data recovery from an ext4 file system that
was corrupt due to a damage of the underlying physical media.

ext4rescue works on disk image and log file produced using
[GNU ddrescue](http://www.gnu.org/software/ddrescue/).
This method is safer and more reliable than reading data directly from the
damaged media.

What can I recover?
-------------------

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
archives can often be uncompressed up to the point of the first damage, etc.
Therefore, ext4rescue tries to recover also these files.

Directory entries are required only to determine the names of the files and
their location within the directory structure. It is possible that the contents
of a file can be fully recovered even though its name is not known.

License
-------

`ext4rescue` is published under the terms of the GNU General Public License,
version 3. See the file `COPYING` for more information.

