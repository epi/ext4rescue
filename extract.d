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
			destPath = buildPath(destPath, d.name ? d.name : text("~~DIR@", d.inodeNum));
			scope(exit) destPath = tempdestPath;
			Directory tempCurrentDir = currentDir;
			currentDir = d;
			scope(exit) currentDir = tempCurrentDir;
			writeln("dir ", destPath);
			mkdirRecurse(destPath);
			foreach (c; d.children)
			{
				writef("child %d {\n    ", c.inodeNum);
				c.accept(this);
				writeln("}");
			}
		}

		string[] getNames(MultiplyLinkedFile mlf)
		{
			if (mlf.links.length == 0)
				return [ text("~~FILE@", f.inodeNum) ];
			string[] result;
			foreach (l; mlf.links)
			{
				if (l.parent.inodeNum == currentDir.inodeNum)
					result ~= l.name;
			}
			return result;
		}

		void visit(RegularFile f)
		{
			foreach (name; getNames(f))
			{
				string path = buildPath(destPath, name);
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
				writeln("file ", path);
				auto file = File(path, "wb");
				auto range = ext4.inodes[f.inodeNum].extents;
				foreach (extent; range)
				{
					if (extent.ok)
					{
						file.seek(extent.logicalBlockNum * ext4.blockSize);
						while (extent.blockCount >= 16)
						{
							auto mme = ext4.cache.mapExtent(extent.physicalBlockNum, 16);
							file.rawWrite(mme[]);
							extent.physicalBlockNum += 16;
							extent.blockCount -= 16;
						}
						if (extent.blockCount)
						{
							auto mme = ext4.cache.mapExtent(extent.physicalBlockNum, extent.blockCount);
							file.rawWrite(mme[]);
						}
					}
				}
				writtenFiles[f.inodeNum] = path;
			}
		}

		void visit(SymbolicLink l)
		{
			string path = buildPath(destPath, getNames(l)[0]);
			writeln("symlink ", path);
		}
	});
}

