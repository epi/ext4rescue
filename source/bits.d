/**
	Functions for manipulating numbers and binary representation of data.

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
module bits;

private template TotalByteCount(T...)
{
	static if (T.length == 0)
		enum TotalByteCount = 0;
	else
		enum TotalByteCount = T[0].sizeof + TotalByteCount!(T[1 .. T.length]);
}

static assert(TotalByteCount!() == 0);
static assert(TotalByteCount!ubyte == 1);
static assert(TotalByteCount!ushort == 2);
static assert(TotalByteCount!uint == 4);
static assert(TotalByteCount!(long, int, short, byte) == 15);

private template BitCatResult(T...)
{
	static if (TotalByteCount!T <= 1)
		alias BitCatResult = ubyte;
	else static if (TotalByteCount!T <= 2)
		alias BitCatResult = ushort;
	else static if (TotalByteCount!T <= 4)
		alias BitCatResult = uint;
	else static if (TotalByteCount!T <= 8)
		alias BitCatResult = ulong;
	else
		static assert(0, T.stringof ~ " is too big");
}

static assert(is(BitCatResult!ubyte == ubyte));
static assert(is(BitCatResult!(ubyte, ubyte) == ushort));
static assert(is(BitCatResult!(ushort, ubyte) == uint));
static assert(is(BitCatResult!(uint, ushort) == ulong));
static assert(is(BitCatResult!(uint, ushort, ubyte) == ulong));
static assert(is(BitCatResult!(uint, uint) == ulong));
static assert(!is(BitCatResult!(uint, uint, ubyte)));

/** Concatenate bits of all arguments.
 *  Examples:
 *  ---------
 *  ubyte b = 0xfe;
 *  ushort s = 0xdecb;
 *  uint i = 0xa987_6543;
 *  assert(bitCat(b) == 0xfe);
 *  assert(bitCat(b, s) == 0xfe_decb);
 *  assert(bitCat(b, i) == 0xfe_a987_6543);
 *  assert(bitCat(b, s, i) == 0xfe_decb_a987_6543);
 *  ---------
 */
auto bitCat(T...)(T t)
{
	static if (T.length == 0)
		return 0;
	else
		return ((cast(BitCatResult!T) t[0]) << 8 * TotalByteCount!(T[1 .. $])) | bitCat(t[1 .. $]);
}

unittest
{
	import std.stdio;
	ubyte b = 0xfe;
	ushort s = 0xdecb;
	uint i = 0xa987_6543;
	assert(bitCat(b) == 0xfe);
	assert(bitCat(b, s) == 0xfe_decb);
	assert(bitCat(b, i) == 0xfe_a987_6543);
	assert(bitCat(b, s, i) == 0xfe_decb_a987_6543);
	assert(bitCat(s, i, s) == 0xdecb_a987_6543_decb);
}
