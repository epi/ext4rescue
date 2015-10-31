module extract;

import std.conv;
import std.path;
import std.stdio;

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

class DirectoryExtractTarget : ExtractTarget
{
	this(string destPath)
	{
		_destPath = destPath;
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
	import core.sys.posix.unistd : link, symlink, lchown;
	import core.sys.linux.sys.xattr : lsetxattr;
	import core.stdc.errno : errno, ENODATA;
	import std.file : errnoEnforce;
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
		import defs : Mode;
		if (!inode.ok)
			return;
		auto pathz = buildPath(_destPath, path).toStringz();
		if (inode.mode.type != Mode.Type.symlink)
		{
			uint mode = inode.mode.mode & octal!"7777";
			errnoEnforce(chmod(pathz, mode) == 0,
				format("Failed to set mode %04o for file %s", mode, path));
		}
		errnoEnforce(lchown(pathz, inode.uid, inode.gid) == 0,
			format("Failed to set uid/gid to %d/%d for file %s", inode.uid, inode.gid, path));
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
}

void extract(SomeFile root, Ext4 ext4, ExtractTarget target)
{
	import std.range : repeat, take;
	root.accept(new class FileVisitor
	{
		Directory currentDir;
		string currentPath;
		string[uint] writtenFiles;

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
			writeln("d ", currentPath);
			target.mkdir(currentPath);
			foreach (c; d.children)
				c.accept(this);
			target.setStatus(currentPath, d.status);
			target.setAttr(currentPath, ext4.inodes[d.inodeNum]);
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
			writeln("h ", path, " -> ", orig);
			target.link(orig, path);
			return true;
		}

		void visit(RegularFile f)
		{
			foreach (name; getNames(f))
			{
				string path = buildPath(currentPath, name);
				if (hardlink(f.inodeNum, path))
					return;
				writeln("f ", path);
				auto stream = target.writeFile(path);
				scope(exit) stream.close();
				auto inode = ext4.inodes[f.inodeNum];
				if (!inode.ok)
					break;
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
				target.setStatus(currentPath, f.status);
				target.setAttr(path, inode);
				writtenFiles[f.inodeNum] = path;
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
				writeln("l ", path, " -> ", orig);
				target.symlink(orig, path);
				target.setStatus(currentPath, l.status);
				target.setAttr(path, inode);
				writtenFiles[l.inodeNum] = path;
			}
		}
	});
}
