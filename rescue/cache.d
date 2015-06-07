/**
	Cache the file tree to avoid rescanning the file system on each run.

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
module rescue.cache;

import std.array;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.file;
import std.path;
import std.stdio;

import rescue.file;

private string getModificationTimeAsString(string filename)
{
	SysTime accessTime;
	SysTime modificationTime;
	getTimes(filename, accessTime, modificationTime);
	return modificationTime.toString();
}

private string getCacheFileName(string imageName, string ddrescueLogName)
{
	auto app = appender!string();
	imageName = absolutePath(imageName);
	app.put(imageName);
	app.put("!");
	app.put(getModificationTimeAsString(imageName));
	if (ddrescueLogName.length)
	{
		ddrescueLogName = absolutePath(ddrescueLogName);
		app.put(ddrescueLogName);
		app.put("!");
		app.put(getModificationTimeAsString(ddrescueLogName));
	}
	auto filename = sha1Of(app.data).toHexString() ~ ".cache";
	return buildPath("~", ".ext4rescue", filename).expandTilde();
}

private enum cacheVersion = 10002;
private enum cacheMinimumVersion = 10002;
private enum cacheMaximumVersion = 10002;

private class CacheWriter : FileVisitor
{
	private File outfile;

	this(File outfile)
	{
		this.outfile = outfile;
	}

	private void writeCommon(SomeFile sf, char type)
	{
		outfile.writef("%s/%d/%d/%d/%d/%d/%d/%d/%d",
			type, sf.inodeNum, sf.linkCount, sf.byteCount, sf.size, sf.inodeIsOk,
			sf.blockMapIsOk, sf.mappedByteCount, sf.readableByteCount);
	}

	private void writeLinks(in SomeFile.Link[] links)
	{
		foreach (link; links)
		{
			outfile.writef("/%d/%s",
				link.parent is null ? 0 : link.parent.inodeNum, link.name);
		}
	}

	void visit(Directory d)
	{
		writeCommon(d, 'd');
		outfile.writefln("/%d/%d/%d/%s",
			d.parent is null ? 0 : d.parent.inodeNum, d.subdirectoryCount, d.parentMismatch, d.name);
	}

	void visit(RegularFile r)
	{
		writeCommon(r, 'r');
		writeLinks(r.links);
		outfile.writeln();
	}

	void visit(SymbolicLink l)
	{
		writeCommon(l, 'l');
		writeLinks(l.links);
		outfile.writeln();
	}
}

///
void cacheFileTree(string imageName, string ddrescueLogName, FileTree fileTree)
{
	auto name = getCacheFileName(imageName, ddrescueLogName);
	mkdirRecurse(name.dirName());
	auto cacheFileName = getCacheFileName(imageName, ddrescueLogName);
	auto outfile = File(cacheFileName, "wb");
	scope(failure) remove(cacheFileName);
	scope(exit) outfile.close();
	outfile.writeln(cacheVersion);
	outfile.writeln(imageName);
	outfile.writeln(ddrescueLogName);
	auto writer = new CacheWriter(outfile);
	foreach (inodeNum, file; fileTree.filesByInodeNum)
		file.accept(writer);
}

private alias Reader = void function(FileTree fileTree, in char[][] fields);
private Reader[string] readers;

private void readCommon(SomeFile sf, in char[][] fields)
{
	sf.linkCount = to!uint(fields[1]);
	sf.byteCount = to!ulong(fields[2]);
	sf.size = to!ulong(fields[3]);
	sf.inodeIsOk = !!to!uint(fields[4]);
	sf.blockMapIsOk = !!to!uint(fields[5]);
	sf.mappedByteCount = to!ulong(fields[6]);
	sf.readableByteCount = to!ulong(fields[7]);
}

private void readLinks(FileTree fileTree, ref SomeFile.Link[] links, const(char[])[] fields)
in
{
	assert((fields.length & 1) == 0);
}
body
{
	while (fields.length)
	{
		uint parentInodeNum = to!uint(fields[0]);
		links ~= RegularFile.Link(
			parentInodeNum == 0 ? null : fileTree.get!Directory(parentInodeNum),
			fields[1].idup);
		fields = fields[2 .. $];
	}
}

private void readRegularFile(FileTree fileTree, in char[][] fields)
{
	enforce(fields.length >= 8 && !(fields.length & 1), "invalid regular file entry");
	auto r = fileTree.get!RegularFile(to!uint(fields[0]));
	readCommon(r, fields);
	readLinks(fileTree, r.links, fields[8 .. $]);
}

private void readDirectory(FileTree fileTree, in char[][] fields)
{
	enforce(fields.length == 12, "invalid directory entry");
	auto d = fileTree.get!Directory(to!uint(fields[0]));
	readCommon(d, fields);
	uint parentInodeNum = to!uint(fields[8]);
	d.parent = parentInodeNum == 0 ? null : fileTree.get!Directory(parentInodeNum);
	d.subdirectoryCount = to!uint(fields[9]);
	d.parentMismatch = !!to!uint(fields[10]);
	d.name = fields[11].idup;
}

private void readSymbolicLink(FileTree fileTree, in char[][] fields)
{
	enforce(fields.length >= 8 && !(fields.length & 1), "invalid symbolic link entry");
	auto l = fileTree.get!SymbolicLink(to!uint(fields[0]));
	readCommon(l, fields);
	readLinks(fileTree, l.links, fields[8 .. $]);
}

static this()
{
	readers["r"] = &readRegularFile;
	readers["d"] = &readDirectory;
	readers["l"] = &readSymbolicLink;
}

///
FileTree readCachedFileTree(string imageName, string ddrescueLogName)
{
	auto name = getCacheFileName(imageName, ddrescueLogName);
	if (!exists(name))
		return null;
	auto infile = File(name);
	auto lines = infile.byLine();

	enforce(!lines.empty, "missing cache version number");
	auto ver = lines.front.to!uint();
	enforce(ver >= cacheMinimumVersion && ver <= cacheMaximumVersion, text("cache version ", ver, " is not supported"));
	lines.popFront();

	enforce(!lines.empty, "missing image name");
	enforce(lines.front == imageName, "image name does not match the cached one");
	lines.popFront();

	enforce(!lines.empty, "missing ddrescue log name");
	enforce(lines.front == ddrescueLogName, "ddrescue log name does not match the cached one");
	lines.popFront();

	auto result = new FileTree;
	while (!lines.empty)
	{
		auto fields = lines.front.split("/");
		enforce(fields.length >= 1, "empty cache entry");
		auto reader = enforce(readers.get(fields[0].assumeUnique(), null), "unknown file type");
		reader(result, fields[1 .. $]);
		lines.popFront();
	}
	return result;
}
