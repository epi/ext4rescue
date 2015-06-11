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

import std.conv;
import std.exception;

import bits;
import blockcache;
import ddrescue;
import defs;
import ext4;
import rescue.file;

/// Scan directory entries and associate inodes with names.
private void scanDirectory(Ext4 ext4, FileTree fileTree, Directory thisDir)
{
	foreach (entry; ext4.inodes[thisDir.inodeNum].readAsDir())
	{
		if (!entry.inode)
			continue;
		//writef("\x1b[2K%10d %d %s\r", entry.inode, entry.file_type, entry.name);
		//stdout.flush();
		if (entry.file_type == ext4_dir_entry_2.Type.dir)
		{
			Directory dir = fileTree.get!Directory(entry.inode);
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
			RegularFile file = fileTree.get!RegularFile(entry.inode);
			file.links ~= RegularFile.Link(thisDir, entry.name.idup);
		}
		else if (entry.file_type == ext4_dir_entry_2.Type.symlink)
		{
			SymbolicLink symlink = fileTree.get!SymbolicLink(entry.inode);
			symlink.links ~= SymbolicLink.Link(thisDir, entry.name.idup);
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

/// Scan inodes and directories in file system ext4
FileTree scan(Ext4 ext4, bool delegate(uint current, uint total) progressDg = null, uint progressStep = 1024)
{
	auto fileTree = new FileTree;
	uint total = ext4.inodes.length;
	uint step = total / 1024;
	foreach (inode; ext4.inodes[])
	{
		if (progressDg && ((inode.inodeNum - 1) % step) == 0)
		{
			if (!progressDg(inode.inodeNum - 1, total))
				return fileTree;
		}
		if (inode.inodeNum != 2 && inode.inodeNum < 11)
			continue;
		if (inode.ok && !inode.i_dtime && inode.mode.type > 0)
		{
			if (inode.mode.type == Mode.Type.dir)
			{
				Directory dir = fileTree.get!Directory(inode.inodeNum);
				setFileProperties(dir, inode);
				scanDirectory(ext4, fileTree, dir);
				checkDataReadability(dir, ext4);
			}
			else if (inode.mode.type == Mode.Type.file)
			{
				RegularFile reg = fileTree.get!RegularFile(inode.inodeNum);
				setFileProperties(reg, inode);
				checkDataReadability(reg, ext4);
			}
			else if (inode.mode.type == Mode.Type.symlink)
			{
				SymbolicLink link = fileTree.get!SymbolicLink(inode.inodeNum);
				setFileProperties(link, inode);
				if (!inode.isFastSymlink)
					checkDataReadability(link, ext4);
				else
					link.blockMapIsOk = true; // FIXME: there's no block map for symlink
			}
		}
	}
	if (progressDg)
		progressDg(total, total);
	return fileTree;
}

private void checkDataReadability(SomeFile sf, Ext4 ext4)
{
	sf.mappedByteCount = 0;
	sf.readableByteCount = 0;
	auto range = ext4.inodes[sf.inodeNum].extents;
	if (!range.ok)
	{
		sf.blockMapIsOk = false;
		return;
	}
	sf.blockMapIsOk = true;
	foreach (Extent extent; range)
	{
		if (!extent.ok)
			sf.blockMapIsOk = false;
		else
		{
			sf.mappedByteCount += ext4.blockSize * extent.length;
			sf.readableByteCount += ext4.cache.ddrescueLog.countReadableBytes(
				extent.start * ext4.blockSize,
				(extent.start + extent.length) * ext4.blockSize);
		}
	}
}

private bool tryBlockAsRootDirData(Ext4 ext4, FileTree fileTree, ulong blockNum)
{
	uint offset = 0;
	while (offset + ext4_dir_entry_2.sizeof < ext4.blockSize)
	{
		auto entry = ext4.cache.requestStruct!ext4_dir_entry_2(blockNum, offset);
		if (!entry.ok)
			break;
		debug entry.dump();
		if (offset + entry.rec_len > ext4.blockSize)
			return false;
		if (offset + ext4_dir_entry_2.name_len.offsetof + entry.name_len > ext4.blockSize)
			return false;
		auto sf = fileTree.get(entry.inode);
		if (sf)
		{
			if (entry.file_type == ext4_dir_entry_2.Type.dir && cast(Directory) sf)
			{
				auto dir = cast(Directory) sf;
				if (dir.parent && dir.parent.inodeNum != 2)
					return false;
				dir.name = entry.name.idup;
			}
			else if (entry.file_type == ext4_dir_entry_2.Type.file && cast(RegularFile) sf)
			{
				auto file = cast(RegularFile) sf;
				if (file.links.length >= file.linkCount)
					return false;
				file.links ~= RegularFile.Link(fileTree.get!Directory(2), entry.name.idup);
			}
		}
		offset += entry.rec_len;
	}
	return true;
}

/// If the root directory inode is not readable, search for the root directory data
/// directly in the data blocks in the first group.
void findRootDirectoryContents(Ext4 ext4, FileTree fileTree)
{
	foreach (ulong blockNum; 1 .. 1 + ext4.superBlock.s_blocks_per_group)
	{
		auto entry1 = ext4.cache.requestStruct!ext4_dir_entry_2(blockNum, 0);
		auto entry2 = ext4.cache.requestStruct!ext4_dir_entry_2(blockNum, 12);
		if (entry1.ok
		 && entry1.inode == 2
		 && entry1.rec_len == 12
		 && entry1.name_len == 1
		 && entry1.file_type == ext4_dir_entry_2.Type.dir
		 && entry1.name == "."
		 && entry2.ok
		 && entry2.inode == 2
		 && entry2.rec_len == 12
		 && entry2.name_len == 2
		 && entry2.file_type == ext4_dir_entry_2.Type.dir
		 && entry2.name == "..")
		{
			if (tryBlockAsRootDirData(ext4, fileTree, blockNum))
				return;
		}
	}
}
