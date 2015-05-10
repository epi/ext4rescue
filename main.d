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

import std.array;
import std.stdio;

import blockcache;
import ddrescue;
import defs;
import ext4;

void main(string[] args)
{
	Region[] regions;
	if (args.length > 2)
		regions = parseLog(File(args[2]).byLine());
	scope ext4 = new Ext4(args[1], regions);
	writefln("Block size:   %12s", ext4.blockSize);
	writefln("Inode count:  %12s", ext4.inodes.length);
	ulong validInodeCount;
	foreach (inode; ext4.inodes[])
	{
		if (inode.ok && inode.i_mode)
		{
			++validInodeCount;
			if (!inode.i_dtime)
				writeln(inode.extents.array());
		}
	}
	writefln("Valid inodes: %12s", validInodeCount);
}