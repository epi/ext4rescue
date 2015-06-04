/**
	ext4rescue main module.

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
module main;

import std.exception;
import std.getopt;
import std.stdio;

import ddrescue;
import ext4;
import rescue.cache;
import rescue.file;
import rescue.scan;

void main(string[] args)
{
	bool forceScan;
	getopt(args, "force-scan", &forceScan);

	enforce(args.length >= 2, "Missing ext4 file system image name");
	string imageName = args[1];
	string ddrescueLogName;
	Region[] regions;
	if (args.length > 2)
	{
		ddrescueLogName = args[2];
		regions = parseLog(File(ddrescueLogName).byLine());
	}
	if (regions.length == 0)
		regions ~= Region(0, getFileSize(imageName), true);
	//regions = regions.addRandomDamage(30, 1024);
	debug writeln(regions);

	scope ext4 = new Ext4(imageName, regions);
	writefln("Block size:   %12s", ext4.blockSize);
	writefln("Inode count:  %12s", ext4.inodes.length);
	ulong validInodeCount;
	debug ext4.superBlock.dump();

	FileTree fileTree;

	if (!forceScan)
	{
		try
		{
			fileTree = readCachedFileTree(imageName, ddrescueLogName);
		}
		catch (Exception e)
		{
			stderr.writeln("Could not read cached file tree: ", e.msg);
		}
	}

	if (!fileTree)
	{
		fileTree = scan(ext4,
			(uint current, uint total) {
				stdout.writef("Scanning inodes and directories... %3d%%\r", current * 100UL / total);
				stdout.flush();
				return true;
			});
		writeln();
		cacheFileTree(imageName, ddrescueLogName, fileTree);
	}

	auto visitor = new ProblemDescriptionVisitor();
	auto namer = new NamingVisitor();
	foreach (k, v; fileTree.filesByInodeNum)
	{
		v.accept(visitor);
		if (visitor.problems.length)
		{
			v.accept(namer);
			writeln(k, " ", namer.names, " ", visitor.problems);
		}
	}
}
