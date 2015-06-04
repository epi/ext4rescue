/**
	Load GNU _ddrescue log files and use them to
	determine validity of data in specific byte ranges of disk images.

	See_Also:
	$(LINK http://www.gnu.org/software/ddrescue/)

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
module ddrescue;

import std.algorithm;
import std.array;
import std.exception;
import std.format;
import std.random;
import std.range;
import std.string;
import std.traits;

/// Describes a region of a disk image as good or damaged.
struct Region
{
	ulong position;
	ulong size;
	bool  good;

	alias begin = position;
	@property ulong end() const pure nothrow { return position + size; }

	/// _ddrescue-like text representation
	string toString() const
	{
		return format("0x%08x  0x%08x  %s", position, size, good ? "+" : "-");
	}
}

/// Returns the total number of bytes in all bad regions.
ulong totalBadByteCount(in Region[] regions) pure
{
	return regions.filter!"!a.good"().map!"a.size"().reduce!"a + b"();
}

/// Returns the index of the region in the input array in which pos is.
size_t locate(in Region[] regions, ulong pos)
{
	size_t b = 0;
	size_t e = regions.length;
	while (e - b > 0)
	{
		size_t i = b + (e - b) / 2;
		if (pos >= regions[i].position && pos < regions[i].end)
			return i;
		else if (pos < regions[i].position)
			e = i;
		else
			b = i + 1;
	}
	throw new Exception(format("Position %s not found in [%(  %s\n%)]", pos, regions));
}

/// Returns true iff all regions are good.
bool allGood(in Region[] regions)
{
	foreach (r; regions)
		if (!r.good)
			return false;
	return true;
}

/// Returns true iff all regions in the file position range [begin, end) are good.
bool allGood(in Region[] regions, ulong begin, ulong end)
{
	size_t bpos = locate(regions, begin);
	size_t epos = locate(regions, end - 1);
	return allGood(regions[bpos .. epos + 1]);
}

/// Returns number of readable bytes within file position range [begin, end).
ulong countReadableBytes(in Region[] regions, ulong begin, ulong end)
in
{
	assert(regions.length >= 1);
	assert(begin >= regions[0].begin);
	assert(begin <= end);
	assert(end <= regions[$ - 1].end);
}
out(result)
{
	assert(result <= end - begin);
}
body
{
	if (begin == end)
		return 0;
	size_t bpos = locate(regions, begin);
	size_t epos = locate(regions, end - 1);
	if (bpos == epos)
		return regions[bpos].good ? end - begin : 0;
	ulong result = 0;
	if (regions[bpos].good)
		result += regions[bpos].end - begin;
	foreach (region; regions[bpos + 1 .. epos])
	{
		if (region.good)
			result += region.size;
	}
	if (regions[epos].good)
		result += end - regions[epos].begin;
	return result;
}

/// Returns number of bytes within file position range [begin, end) which are bad.
ulong countUnreadableBytes(in Region[] regions, ulong begin, ulong end)
{
	return end - begin - countReadableBytes(regions, begin, end);
}

/// Parses a ddrescue log file, returning an array of regions.
Region[] parseLog(R)(R lines) if (isSomeString!(ElementType!R))
{
	Region[] regions;
	foreach (line; lines)
	{
		auto l = chomp(line);
		if (l.length == 0 || l.startsWith('#'))
			continue;
		auto fields = l.split();
		if (fields.length != 3)
			continue;
		ulong position;
		ulong size;
		char status;
		if (1 != formattedRead(fields[0], "0x%x", &position))
			continue;
		if (1 != formattedRead(fields[1], "0x%x", &size))
			continue;
		if (fields[2].length != 1)
			continue;
		status = fields[2][0];
		if (regions.length && regions[$ - 1].end != position)
			throw new Exception("Non-contiguous region in the log file");
		regions ~= Region(position, size, status == '+');
	}
	return regions;
}

Region[] addRandomDamage(ref Region[] regions, ulong count, ulong maxLength)
{
	auto rnd = Random(1);
	auto imageLength = regions[$ - 1].end / 512;

	Region[] result;
	while (count--)
	{
		import std.stdio;
		ulong length = uniform(0, maxLength, rnd);
		ulong begin = uniform(0, imageLength - length, rnd);
		length *= 512;
		begin *= 512;
		ulong end = begin + length;
		size_t bpos = locate(regions, begin);
		size_t epos = locate(regions, begin + length);
		result = regions[0 .. bpos];
		if (begin != regions[bpos].begin)
			result ~= Region(regions[bpos].begin, begin - regions[bpos].begin, regions[bpos].good);
		result ~= Region(begin, length, false);
		if (end != regions[epos].end)
		{
			ulong overlapLength = regions[epos].end - end;
			result ~= Region(regions[epos].end - overlapLength, overlapLength, regions[epos].good);
		}
		result ~= regions[epos + 1 .. $];
		regions = result;
	}
	return result;
}

unittest
{
	auto logfile = r"
# Rescue Logfile. Created by GNU ddrescue version 1.14
# Command line: ddrescue -B -S -r 3 -T -d /dev/sdc3 f.dat f.log
# current_pos  current_status
0x46FFFBD200     -
#      pos        size  status
0x00000000  0x00404000  +
0x00404000  0x00008000  -
0x0040C000  0x00015000  +
0x00421000  0x00001000  -
0x00422000  0x3801BFE000  +
0x3802020000  0x00004000  -
0x3802024000  0x12fe1f1000 +
0x4B00215000  0x00007000  -
0x4B0021C000  0x1F31EE4000  +";
	auto regions = parseLog(logfile.split("\n"));
	foreach (i; iota(0, regions.length, 2))
		assert(allGood(regions[i .. i + 1]));
	assert(regions[$ - 1].end == 0x6a32100000);
	assert(regions.totalBadByteCount() == 0x8000 + 0x1000 + 0x4000 + 0x7000);
	assert(regions.locate(0x2) == 0);
	assert(regions.locate(0x406080) == 1);
	assert(regions.locate(0x5000000000) == regions.length - 1);
	assertThrown(regions.locate(0x7000000000));
}
