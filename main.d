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

import ext4;
import ddrescue;
import rescue;

import std.algorithm;
import std.bitmanip;
import std.container.rbtree;
import std.format;
import std.stdio;

void main(string[] args)
{
	Region[] regions;
	if (args.length > 2)
		regions = parseLog(File(args[2]).byLine());
	if (regions.length == 0)
		regions ~= Region(0, getFileSize(args[1]), true);
	writeln(regions);
	//regions = regions.addRandomDamage(30, 1024);
	writeln(regions);
	scope ext4 = new Ext4(args[1], regions);
	writefln("Block size:   %12s", ext4.blockSize);
	writefln("Inode count:  %12s", ext4.inodes.length);
	ulong validInodeCount;
	ext4.superBlock.dump();
	auto rescue = new Rescue(ext4);
	rescue.scan();
}
