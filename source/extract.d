module extract;

import std.conv;
import std.file;
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
}

class DirectoryExtractTarget : ExtractTarget
{
	this(string destPath)
	{
		_destPath = destPath;
	}

	void mkdir(in char[] path)
	{
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

	import core.sys.posix.unistd : link, symlink;
	import std.file : errnoEnforce;
	import std.string : toStringz;

	void link(in char[] oldPath, in char[] newPath)
	{
		errnoEnforce(link(
			buildPath(_destPath, oldPath).toStringz(),
			buildPath(_destPath, newPath).toStringz()) == 0);
	}

	void symlink(in char[] oldPath, in char[] newPath)
	{
		errnoEnforce(symlink(
			buildPath(_destPath, oldPath).toStringz(),
			buildPath(_destPath, newPath).toStringz()) == 0);
	}

	private string _destPath;
}

void extract(SomeFile root, Ext4 ext4, ExtractTarget target)
{
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
			writeln("dir ", currentPath);
			target.mkdir(currentPath);
			foreach (c; d.children)
				c.accept(this);
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
			writeln("hardlink ", path, " -> ", orig);
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
				writeln("file ", path);
				auto stream = target.writeFile(path);
				scope(exit) stream.close();
				auto inode = ext4.inodes[f.inodeNum];
				auto range = inode.extents;
				while (!range.empty)
				{
					auto extent = range.front;
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
							enforce(len <= mme.length, "Invalid file size");
							stream.rawWrite(mme[0 .. len]);
						}
					}
				}
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
				string orig = inode.getSymlinkTarget();
				writeln("symlink ", path, " -> ", orig);
				target.symlink(orig, path);
				writtenFiles[l.inodeNum] = path;
			}
		}
	});
}
