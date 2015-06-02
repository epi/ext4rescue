/**
	Scan inodes and directories.

	Copyright:
	This file is part of ext4rescue $(LINK https://github.com/epi/ext4rescue)
	Copyright (C) 2014 Adrian Matoga

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
module rescue.scan;

import std.stdio;

import bits;
import blockcache;
import defs;
import ext4;

import rescue.file;

class Scanner
{
	private Ext4 _ext4;
	SomeFile[uint] filesByInodeNum;

	this(Ext4 ext4)
	{
		_ext4 = ext4;
	}

	private T getFile(T)(uint inodeNum)
		if (is(T : SomeFile))
	{
		auto item = cast(T) filesByInodeNum.get(inodeNum, null);
		if (!item)
		{
			item = new T(inodeNum);
			filesByInodeNum[inodeNum] = item;
		}
		return item;
	}

	/// Scan directory entries and associate inodes with names.
	private void scanDirectory(Directory thisDir)
	{
		foreach (entry; _ext4.inodes[thisDir.inodeNum].readAsDir())
		{
			if (!entry.inode)
				continue;
			//writef("\x1b[2K%10d %d %s\r", entry.inode, entry.file_type, entry.name);
			//stdout.flush();
			if (entry.file_type == ext4_dir_entry_2.Type.dir)
			{
				Directory dir = getFile!Directory(entry.inode);
				if (entry.name == ".")
				{}
				else if (entry.name == "..")
				{
					// entry points to the parent of thisDir
					associateParentWithDir(dir, thisDir);
				}
				else
				{
					dir.name = entry.name.idup;
					// thisDir is the parent of current entry
					associateParentWithDir(thisDir, dir);
				}
			}
			else if (entry.file_type == ext4_dir_entry_2.Type.file)
			{
				RegularFile file = getFile!RegularFile(entry.inode);
				file.links ~= RegularFile.Link(thisDir, entry.name.idup);
			}
		}
	}

	private void associateParentWithDir(Directory parent, Directory dir)
	{
		if (!dir.parent)
		{
			dir.parent = parent;
			++parent.subdirectoryCount;
		}
		else if (dir.parent !is parent)
			dir.parentMismatch = true;
	}

	private void setFileProperties(SomeFile file, Ext4.Inode inode)
	{
		file.inodeIsOk = inode.ok;
		file.linkCount = inode.i_links_count;
		file.byteCount = inode.blockCount * 512;
		file.size = inode.size;
	}

	uint unreadableInodes;

	void scan(void delegate(uint current, uint total) progressDg = null, uint progressStep = 1024)
	{
		uint total = _ext4.inodes.length;
		uint step = total / 1024;
		foreach (inode; _ext4.inodes[])
		{
			if (progressDg && ((inode.inodeNum - 1) % step) == 0)
				progressDg(inode.inodeNum - 1, total);
			if (inode.inodeNum != 2 && inode.inodeNum < 11)
				continue;
			if (!inode.ok)
				++unreadableInodes;
			if (inode.ok && !inode.i_dtime)
			{
				if (inode.mode.type == Mode.Type.dir)
				{
					Directory dir = getFile!Directory(inode.inodeNum);
					setFileProperties(dir, inode);
					scanDirectory(dir);
				}
				else if (inode.mode.type == Mode.Type.file)
				{
					RegularFile reg = getFile!RegularFile(inode.inodeNum);
					setFileProperties(reg, inode);
				}
			}
		}
		if (progressDg)
			progressDg(total, total);
		writeln("\nsearch complete");
		writeln(filesByInodeNum.length);
		auto visitor = new ProblemDescriptionVisitor();
		auto namer = new NamingVisitor();
		foreach (k, v; filesByInodeNum)
		{
			v.accept(visitor);
			if (visitor.problems.length)
			{
				v.accept(namer);
				writeln(k, " ", namer.names, " ", visitor.problems);
			}
		}
	}
}
