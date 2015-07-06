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
module filetree;

import std.bitmanip;
import std.conv;
import std.exception;
import std.format;
import std.path;

/// Root of the hierarchy
abstract class SomeFile
{
	struct Link
	{
		Directory parent;
		string name;
	}

	uint inodeNum;
	uint linkCount;
	ulong byteCount;
	ulong size;
	ulong mapByteCount;
	ulong reachableByteCount;
	ulong readableByteCount;
	bool inodeIsOk;
	bool blockMapIsOk;

	///
	final @property bool ok() const pure nothrow
	{
		return status.ok;
	}

	///
	@property FileStatus status() const pure nothrow
	{
		FileStatus result;
		if (!inodeIsOk)
		{
			result.badInode = true;
			assert(!result.missingLinks);
			return result;
		}
		if (!blockMapIsOk)
			result.badMap = true;
		if (readableByteCount < reachableByteCount)
			result.badData = true;
		assert(!result.missingLinks);
		return result;
	}

	///
	abstract @property uint foundLinkCount() const pure nothrow;

	///
	this(uint inodeNum)
	{
		this.inodeNum = inodeNum;
	}

	///
	abstract void accept(FileVisitor v);
}

interface FileVisitor
{
	void visit(Directory d);
	void visit(RegularFile f);
	void visit(SymbolicLink l);
}

private
{
	mixin template CtorInodeNum()
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
	bool parentMismatch;
	string name;
	SomeFile[] children;

	mixin CtorInodeNum;
	mixin AcceptVisitor;

	@property uint subdirectoryCount() const pure nothrow { return cast(uint) children.length; }

	override @property FileStatus status() const pure nothrow
	{
		auto result = super.status;
		if (inodeIsOk && subdirectoryCount != linkCount - 2)
			result.missingLinks = true;
		if (inodeNum == 2)
			return result;
		if (parent is null || parentMismatch)
			result.parentUnknown = true;
		if (name is null)
		{
			result.nameUnknown = true;
			result.missingLinks = true;
		}
		return result;
	}

	///
	override @property uint foundLinkCount() const pure nothrow
	{
		return subdirectoryCount + 1 + !!name;
	}
}

///
abstract class MultiplyLinkedFile : SomeFile
{
	Link[] links;

	mixin CtorInodeNum;

	override @property FileStatus status() const pure nothrow
	{
		FileStatus result = super.status;
		if (!inodeIsOk)
			return result;
		if (links.length != linkCount)
		{
			result.missingLinks = true;
			if (links.length == 0)
			{
				result.nameUnknown = true;
				result.parentUnknown = true;
			}
		}
		return result;
	}

	override @property uint foundLinkCount() const pure nothrow
	{
		return cast(uint) links.length;
	}
}

///
class RegularFile : MultiplyLinkedFile
{
	mixin CtorInodeNum;
	mixin AcceptVisitor;
}

///
class SymbolicLink : MultiplyLinkedFile
{
	mixin CtorInodeNum;
	mixin AcceptVisitor;
}

///
class FileTree
{
	///
	SomeFile[uint] filesByInodeNum;

	private SomeFile[] _roots;
	///
	@property SomeFile[] roots() { return _roots; }

	///
	void updateRoots()
	{
		_roots.length = 0;
		auto visitor = new class FileVisitor
		{
			void visitMLF(MultiplyLinkedFile m)
			{
				if (m.links.length == 0)
					_roots ~= m;
			}
			void visit(Directory d)
			{
				if (!d.parent)
					_roots ~= d;
			}
			void visit(RegularFile f)
			{
				visitMLF(f);
			}
			void visit(SymbolicLink l)
			{
				visitMLF(l);
			}
		};
		foreach (f; filesByInodeNum)
			f.accept(visitor);
	}

	///
	T get(T = SomeFile)(uint inodeNum)
		if (is(T : SomeFile))
	{
		SomeFile file = filesByInodeNum.get(inodeNum, null);
		if (!file)
		{
			static if (is(T == SomeFile))
			{
				return null;
			}
			else
			{
				auto newFile = new T(inodeNum);
				filesByInodeNum[inodeNum] = newFile;
				return newFile;
			}
		}
		return enforce(cast(T) file,
			text(inodeNum, " is of type ", typeid(file).name, " but ", typeid(T).name, " was requested"));
	}
}

class NamingVisitor : FileVisitor
{
	private string getDirectoryName(in Directory dir)
	{
		if (dir.name)
			return dir.name;
		return format("~~DIR@%d", dir.inodeNum);
	}

	private string prependWithParentPath(in Directory parent, string name)
	{
		assert(name.length > 0);
		if (!parent)
			return buildPath("~~@UNKNOWN_PARENT", name);
		else if (parent.inodeNum == 2)
			return buildPath("/", name);
		else
			return prependWithParentPath(parent.parent, buildPath(getDirectoryName(parent),  name));
	}

	private bool setFromLinks(in SomeFile.Link[] links)
	{
		names.length = 0;
		if (links.length)
		{
			foreach (link; links)
				names ~= prependWithParentPath(link.parent, link.name);
		}
		return links.length > 0;
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
		if (!setFromLinks(f.links))
			names = [ prependWithParentPath(null, format("~~FILE@%d", f.inodeNum)) ];
	}

	void visit(SymbolicLink l)
	{
		if (!setFromLinks(l.links))
			names = [ prependWithParentPath(null, format("~~SYMLINK@%d", l.inodeNum)) ];
	}

	string[] nameFile(SomeFile f)
	{
		f.accept(this);
		return names;
	}

	string[] names;
}

struct FileStatus
{
	union
	{
		mixin(bitfields!(
			bool, "badInode", 1,
			bool, "parentUnknown", 1,
			bool, "nameUnknown", 1,
			bool, "missingLinks", 1,
			bool, "badMap", 1,
			bool, "badData", 1,
			uint, "__reserved", 26));
		uint status;
	}

	@property void toString(scope void delegate(const(char)[]) sink)
	{
		foreach (i; 0 .. 6)
			sink((status & (1 << i)) ? "ipnlmd"[i .. i + 1] : "-");
	}

	@property bool ok() const pure nothrow { return status == 0; }
}

unittest
{
	import std.stdio;
	SomeFile f = new RegularFile(10);
	f.inodeIsOk = true;
	f.linkCount = 1;
	f.blockMapIsOk = true;
	assert(to!string(f.status) == "-pnl--");
	f.inodeIsOk = false;
	assert(to!string(f.status) == "i-----");
}

deprecated
class ProblemDescriptionVisitor : FileVisitor
{
	private bool checkCommon(SomeFile sf)
	{
		problems.length = 0;
		if (!sf.inodeIsOk)
		{
			problems ~= "Inode could not be read";
			return false;
		}
		if (!sf.blockMapIsOk)
			problems ~= "Block map or extent tree is damaged";
		if (sf.reachableByteCount != sf.readableByteCount)
			problems ~= format("Only %d of %d (%g%%) reachable data bytes are readable",
				sf.readableByteCount, sf.reachableByteCount, sf.readableByteCount * 100.0 / sf.reachableByteCount);
		return true;
	}

	private void checkLinks(in SomeFile.Link[] links, uint linkCount)
	{
		if (links.length == 0)
			problems ~= "No link found";
		else if (links.length < linkCount)
			problems ~= format("Only %d of %d links found", links.length, linkCount);
	}

	void visit(Directory d)
	{
		if (!checkCommon(d))
			return;
		if (d.subdirectoryCount != d.linkCount - 2)
			problems ~= format("Only %d of %d subdirectories found", d.subdirectoryCount, d.linkCount - 2);
		if (d.inodeNum == 2)
			return;
		if (d.parent is null)
			problems ~= "Parent not known";
		if (d.parentMismatch)
			problems ~= "Parent link mismatch";
		if (d.name is null)
			problems ~= "Name not known";
	}

	void visit(RegularFile f)
	{
		if (!checkCommon(f))
			return;
		checkLinks(f.links, f.linkCount);
	}

	void visit(SymbolicLink l)
	{
		if (!checkCommon(l))
			return;
		checkLinks(l.links, l.linkCount);
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
