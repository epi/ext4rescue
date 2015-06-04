/**
	Classes representing file types.

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
module rescue.file;

import std.conv;
import std.exception;
import std.format;
import std.path;

/// Root of the hierarchy
abstract class SomeFile
{
	uint inodeNum;
	uint linkCount;
	ulong byteCount;
	ulong size;
	bool inodeIsOk;

	this(uint inodeNum)
	{
		this.inodeNum = inodeNum;
	}

	abstract void accept(FileVisitor v);
}

interface FileVisitor
{
	void visit(Directory d);
	void visit(RegularFile f);
}

private
{
	mixin template BasicCtor()
	{
		this(uint inodeNum)
		{
			super(inodeNum);
		}
	}

	mixin template AcceptVisitor()
	{
		override void accept(FileVisitor v)
		{
			v.visit(this);
		}
	}
}

///
class Directory : SomeFile
{
	Directory parent;
	uint subdirectoryCount;
	bool parentMismatch;
	string name;

	mixin BasicCtor;
	mixin AcceptVisitor;
}

///
class RegularFile : SomeFile
{
	static struct Link
	{
		Directory parent;
		string name;
	}
	Link[] links;

	mixin BasicCtor;
	mixin AcceptVisitor;
}

///
class FileTree
{
	SomeFile[uint] filesByInodeNum;

	private T get(T = SomeFile)(uint inodeNum)
		if (is(T : SomeFile))
	{
		SomeFile file = filesByInodeNum.get(inodeNum, null);
		if (!file)
		{
			auto newFile = new T(inodeNum);
			filesByInodeNum[inodeNum] = newFile;
			return newFile;
		}
		return enforce(cast(T) file,
			text(inodeNum, " is of type ", typeid(file).name, " but ", typeid(T).name, " was requested"));
	}
}

class NamingVisitor : FileVisitor
{
	private string getDirectoryName(Directory dir)
	{
		if (dir.name)
			return dir.name;
		return format("~~DIR@%d", dir.inodeNum);
	}

	private string prependWithParentPath(Directory parent, string name)
	{
		assert(name.length > 0);
		if (!parent)
			return buildPath("~~@UNKNOWN_PARENT", name);
		else if (parent.inodeNum == 2)
			return buildPath("/", name);
		else
			return prependWithParentPath(parent.parent, buildPath(getDirectoryName(parent),  name));
	}

	void visit(Directory d)
	{
		if (d.inodeNum == 2)
			names = [ "/" ];
		else
			names = [ prependWithParentPath(d.parent, getDirectoryName(d)) ];
	}

	void visit(RegularFile f)
	{
		names.length = 0;
		if (f.links.length)
		{
			foreach (link; f.links)
				names ~= prependWithParentPath(link.parent, link.name);
		}
		else
			names = [ prependWithParentPath(null, format("~~FILE@%d", f.inodeNum)) ];
	}

	string[] names;
}

class ProblemDescriptionVisitor : FileVisitor
{
	private bool checkInode(SomeFile ri)
	{
		problems.length = 0;
		if (!ri.inodeIsOk)
			problems ~= "Inode could not be read";
		return ri.inodeIsOk;
	}

	void visit(Directory d)
	{
		if (!checkInode(d))
			return;
		if (d.parent is null)
			problems ~= "Parent not known";
		if (d.parentMismatch)
			problems ~= "Parent link mismatch";
		if (d.name is null)
			problems ~= "Name not known";
		if (d.subdirectoryCount != d.linkCount - 2)
			problems ~= format("Only %d of %d subdirectories found", d.subdirectoryCount, d.linkCount - 2);
	}

	void visit(RegularFile f)
	{
		if (!checkInode(f))
			return;
		if (f.links.length == 0)
			problems ~= "No link found";
		else if (f.links.length < f.linkCount)
			problems ~= "Some links not found";
	}

	string[] problems;
}

unittest
{
	auto root = new Directory(2);
	auto dir1 = new Directory(123);
	dir1.parent = root;
	dir1.name = "dir1";
	auto dir2 = new Directory(234);
	auto file1 = new RegularFile(412);
	auto visitor = new NamingVisitor();
	visitor.visit(root);
	assert(visitor.names[] == [ "/" ]);
	visitor.visit(dir1);
	assert(visitor.names[] == [ "/dir1" ]);
	root.inodeIsOk = false;
	visitor.visit(dir1);
	assert(visitor.names[] == [ "/dir1" ]);
	visitor.visit(dir2);
	assert(visitor.names[] == [ "~~@UNKNOWN_PARENT/~~DIR@234" ]);
	dir2.name = "dir2";
	visitor.visit(dir2);
	assert(visitor.names[] == [ "~~@UNKNOWN_PARENT/dir2" ]);
	dir2.parent = dir1;
	visitor.visit(dir2);
	assert(visitor.names[] == [ "/dir1/dir2" ]);
	visitor.visit(file1);
	assert(visitor.names[] == [ "~~@UNKNOWN_PARENT/~~FILE@412" ]);
	file1.links ~= RegularFile.Link(dir2, "file1");
	visitor.visit(file1);
	assert(visitor.names[] == [ "/dir1/dir2/file1" ]);
	file1.links ~= RegularFile.Link(dir1, "file1");
	visitor.visit(file1);
	assert(visitor.names[] == [ "/dir1/dir2/file1", "/dir1/file1" ]);
}
