/**
	Extract files from the image.

	Copyright:
	This file is part of ext4rescue $(LINK https://github.com/epi/ext4rescue)
	Copyright (C) 2015 Adrian Matoga

	ext4rescue is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	ext4rescue is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with ext4rescue.  If not, see $(LINK http://www.gnu.org/licenses/).
*/
module extract;

import std.conv;
import std.path;
import std.stdio : File;

import ext4;
import filetree;

interface OutputStream
{
	void seek(ulong offset);
	void rawWrite(in ubyte[] buf);
	void close();
}

interface ExtractTarget
{
	void mkdir(in char[] path);
	OutputStream writeFile(in char[] path);
	void link(in char[] oldPath, in char[] newPath);
	void symlink(in char[] oldPath, in char[] newPath);
	void setAttr(in char[] path, Ext4.Inode inode);
	void setStatus(in char[] path, FileStatus status);
}

private
{
	import core.sys.posix.time : timespec;
	import core.time : Duration;
	extern(C) int utimensat(int dirfd, const(char)* pathname, const(timespec)* times, int flags);
	enum AT_FDCWD = -100;
	enum AT_SYMLINK_NOFOLLOW = 0x100;

	void mktspec(ref timespec ts, Duration d)
	{
		d.split!("seconds", "nsecs")(ts.tv_sec, ts.tv_nsec);
	}
}

class DirectoryExtractTarget : ExtractTarget
{
	this(string destPath, bool chown)
	{
		import std.conv : text;
		import std.exception : enforce;
		import std.file : exists;
		enforce(!exists(destPath), text(`"`, destPath, `" already exists`));
		_destPath = destPath;
		_chown = chown;
	}

	void mkdir(in char[] path)
	{
		import std.file : mkdirRecurse;
		mkdirRecurse(buildPath(_destPath, path));
	}

	OutputStream writeFile(in char[] path)
	{
		return new class OutputStream {
			this()
			{
				_file = File(buildPath(_destPath, path), "wb");
			}
			void seek(ulong offset)
			{
				_file.seek(offset);
			}
			void rawWrite(in ubyte[] buf)
			{
				_file.rawWrite(buf);
			}
			void close()
			{
				_file.close();
			}
			private File _file;
		};
	}

	import core.sys.posix.sys.stat : chmod;
	import core.sys.posix.unistd : link, symlink;
	version (CRuntime_Musl) {
		import core.sys.posix.unistd : uid_t, gid_t;
		// TODO: PR to druntime, lchown's been in musl for a long time already
		extern(C) pragma(mangle, "lchown") static int lchown(const char *path, uid_t uid, gid_t gid);
	} else {
		import core.sys.posix.unistd : lchown;
	}
	import core.sys.linux.sys.xattr : lsetxattr;
	import core.stdc.errno : errno, ENODATA;
	import std.exception : errnoEnforce;
	import std.string : toStringz, format;

	void link(in char[] oldPath, in char[] newPath)
	{
		errnoEnforce(link(
			buildPath(_destPath, oldPath).toStringz(),
			buildPath(_destPath, newPath).toStringz()) == 0,
			format("Failed to create hard link %s -> %s", newPath, oldPath));
	}

	void symlink(in char[] oldPath, in char[] newPath)
	{
		errnoEnforce(symlink(
			oldPath.toStringz(),
			buildPath(_destPath, newPath).toStringz()) == 0,
			format("Failed to create symbolic link %s -> %s", newPath, oldPath));
	}

	void setAttr(in char[] path, Ext4.Inode inode)
	{
		import std.datetime : SysTime, DateTime;
		import defs : Mode;

		if (!inode.ok)
			return;
		auto pathz = buildPath(_destPath, path).toStringz();
		timespec[2] times;
		auto epoch = SysTime(DateTime(1970, 1, 1));
		mktspec(times[0], inode.atime - epoch);
		mktspec(times[1], inode.mtime - epoch);
		errnoEnforce(utimensat(AT_FDCWD, pathz, times.ptr, AT_SYMLINK_NOFOLLOW) == 0,
			format("Failed to set times for file %s", path));
		if (inode.mode.type != Mode.Type.symlink)
		{
			uint mode = inode.mode.mode & octal!"7777";
			errnoEnforce(chmod(pathz, mode) == 0,
				format("Failed to set mode %04o for file %s", mode, path));
		}
		if (_chown)
		{
			errnoEnforce(lchown(pathz, inode.uid, inode.gid) == 0,
				format("Failed to set uid/gid to %d/%d for file %s", inode.uid, inode.gid, path));
		}
	}

	void setStatus(in char[] path, FileStatus status)
	{
		auto pathz = buildPath(_destPath, path).toStringz();
		if (!status.ok)
		{
			auto statstr = format("%s", status);
			errnoEnforce(lsetxattr(pathz, "user.ext4rescue.status", statstr.ptr, statstr.length, 0) == 0,
				format("Failed to set status for file %s (lsetxattr)", path));
		}
	}

	private string _destPath;
	private bool _chown;
}

enum ExtractType
{
	file,
	dir,
	symlink,
	hardlink,
}

void countFilesAndBytes(SomeFile root, Ext4 ext4, out uint fileCount, out ulong byteCount)
{
	uint localFileCount;
	ulong localByteCount;

	root.accept(new class FileVisitor
		{
			void visit(Directory d)
			{
				foreach (c; d.children)
					c.accept(this);
				localFileCount += 1;
				localByteCount += d.byteCount;
			}

			void visit(RegularFile f)
			{
				localFileCount += f.linkCount == 0 ? 1 : f.linkCount;
				localByteCount += f.byteCount;
			}

			void visit(SymbolicLink l)
			{
				localFileCount += l.linkCount == 0 ? 1 : l.linkCount;
				localByteCount += l.byteCount;
			}
		});
	fileCount = localFileCount;
	byteCount = localByteCount;
}

void extract(SomeFile root, Ext4 ext4, ExtractTarget target,
	scope bool delegate(ulong writtenByteCount, ExtractType type, in char[] path, in char[] dest) progressDg)
{
	import std.range : repeat, take;
	root.accept(new class FileVisitor
	{
		Directory currentDir;
		string currentPath;
		string[uint] writtenFiles;
		ulong writtenByteCount;
		bool stop;

		private string getName(Directory d)
		{
			if (d.name)
				return d.name;
			if (d.inodeNum == 2)
				return "";
			return text("~~DIR@", d.inodeNum);
		}

		void visit(Directory d)
		{
			string tempCurrentPath = currentPath;
			currentPath = buildPath(currentPath, getName(d));
			scope(exit) currentPath = tempCurrentPath;
			Directory tempCurrentDir = currentDir;
			currentDir = d;
			scope(exit) currentDir = tempCurrentDir;
			if (progressDg(writtenByteCount, ExtractType.dir, currentPath, ""))
			{
				stop = true;
				return;
			}
			target.mkdir(currentPath);
			foreach (c; d.children)
			{
				c.accept(this);
				if (stop)
					break;
			}
			target.setStatus(currentPath, d.status);
			target.setAttr(currentPath, ext4.inodes[d.inodeNum]);
			writtenByteCount += d.byteCount;
		}

		private string[] getNames(MultiplyLinkedFile mlf)
		{
			if (mlf.links.length == 0)
				return [ text("~~FILE@", mlf.inodeNum) ];
			string[] result;
			foreach (l; mlf.links)
			{
				if (l.parent.inodeNum == currentDir.inodeNum)
					result ~= l.name;
			}
			return result;
		}

		private bool hardlink(uint inodeNum, in char[] path)
		{
			string orig = writtenFiles.get(inodeNum, null);
			if (!orig)
				return false;
			if (progressDg(writtenByteCount, ExtractType.hardlink, path, orig))
			{
				stop = true;
				return true;
			}
			target.link(orig, path);
			return true;
		}

		void writeFileData(in char[] path, Ext4.Inode inode)
		{
			auto stream = target.writeFile(path);
			scope(exit) stream.close();
			if (!inode.ok) // leave an empty file if the inode is bad
				return;
			auto range = inode.extents;
			while (!range.empty)
			{
				Extent extent = range.front;
				range.popFront();
				if (extent.ok && extent.blockCount)
				{
					ulong offset = extent.logicalBlockNum * ext4.blockSize;
					stream.seek(offset);
					enum chunkSize = 32;
					while (extent.blockCount > chunkSize)
					{
						auto mme = ext4.cache.mapExtent(extent.physicalBlockNum, chunkSize);
						stream.rawWrite(mme[]);
						extent.logicalBlockNum += chunkSize;
						extent.physicalBlockNum += chunkSize;
						extent.blockCount -= chunkSize;
					}
					auto mme = ext4.cache.mapExtent(extent.physicalBlockNum, extent.blockCount);
					if (!range.empty)
						stream.rawWrite(mme[]);
					else
					{
						import std.exception : enforce;
						offset = extent.logicalBlockNum * ext4.blockSize;
						size_t len = cast(size_t) inode.size - offset;
						if (len <= mme.length)
							stream.rawWrite(mme[0 .. len]);
						else // there might be unallocated blocks at the end of the file
							stream.rawWrite(mme[]);
					}
				}
			}
		}

		void visit(RegularFile f)
		{
			foreach (name; getNames(f))
			{
				string path = buildPath(currentPath, name);
				if (hardlink(f.inodeNum, path))
					continue;
				if (progressDg(writtenByteCount, ExtractType.file, path, ""))
				{
					stop = true;
					return;
				}
				Ext4.Inode inode = ext4.inodes[f.inodeNum];
				writeFileData(path, inode);
				target.setStatus(path, f.status);
				target.setAttr(path, inode);
				writtenFiles[f.inodeNum] = path;
				writtenByteCount += f.byteCount;
			}
		}

		void visit(SymbolicLink l)
		{
			foreach (name; getNames(l))
			{
				string path = buildPath(currentPath, name);
				if (hardlink(l.inodeNum, path))
					return;
				auto inode = ext4.inodes[l.inodeNum];
				if (!inode.ok)
					return;
				string orig = inode.getSymlinkTarget();
				if (progressDg(writtenByteCount, ExtractType.symlink, path, orig))
				{
					stop = true;
					return;
				}
				target.symlink(orig, path);
				target.setStatus(path, l.status);
				target.setAttr(path, inode);
				writtenFiles[l.inodeNum] = path;
				writtenByteCount += l.byteCount;
			}
		}
	});
}
