module extract;

import std.conv;
import std.file;
import std.path;
import std.stdio;

import ext4;
import filetree;

void extract(SomeFile f, Ext4 ext4, string destPath)
{
	string[uint] writtenFiles;

	f.accept(new class FileVisitor
	{
		Directory currentDir;

		void visit(Directory d)
		{
			string tempdestPath = destPath;
			scope(exit) destPath = tempdestPath;
			Directory tempCurrentDir = currentDir;
			scope(exit) tempCurrentDir = currentDir;
			destPath = buildPath(destPath, d.name ? d.name : text("~~DIR@", d.inodeNum));
			writeln("create   ", destPath);
			mkdirRecurse(destPath);
			foreach (c; d.children)
			{
				writeln(c);
				c.accept(this);
			}
		}

		string getName(MultiplyLinkedFile mlf)
		{
			if (mlf.links.length == 0)
				return text("~~FILE@", f.inodeNum);
			foreach (l; mlf.links)
			{
				if (l.parent is currentDir)
					return l.name;
			}
			return mlf.links[0].name;
		}

		void visit(RegularFile f)
		{
			writeln("file");
			string path = buildPath(destPath, getName(f));
			string orig = writtenFiles.get(f.inodeNum, null);
			if (orig)
			{
				import core.sys.posix.unistd : link;
				import std.file : errnoEnforce;
				import std.string : toStringz;
				writeln("hardlink ", path, " -> ", orig);
				errnoEnforce(link(orig.toStringz(), path.toStringz()) == 0);
				return;
			}
			writeln("write   ", path);
			auto file = File(path, "wb");
			auto range = ext4.inodes[f.inodeNum].extents;
			foreach (extent; range)
			{
				if (extent.ok)
				{
					file.seek(extent.logicalBlockNum * ext4.blockSize);
					foreach (blockNum; extent.physicalBlockNum .. extent.physicalBlockNum + extent.blockCount)
					{
						auto block = ext4.cache.request(blockNum);
						file.rawWrite(block[]);
					}
				}
			}
			writtenFiles[f.inodeNum] = path;
		}

		void visit(SymbolicLink l)
		{
			string name = buildPath(destPath, getName(l));
			writeln("symlink  ", name);
		}
	});
}

