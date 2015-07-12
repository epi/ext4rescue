/**
	Open an ext[234] file system and load various types of data structures.

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
module ext4;

import std.array: Appender, appender;
import std.conv;
import std.exception;
import std.format;
import std.stdio;
import std.typecons;

import bits;
import blockcache;
import ddrescue;
import defs;

ulong getFileSize(const(char)[] name)
{
	auto file = File(name.idup, "rb");
	file.seek(0, SEEK_END);
	return file.tell();
}

private struct Stack(T)
{
	Appender!(T[]) _app;
	@property ref inout(T) top() inout { return _app.data[$ - 1]; };
	@property bool empty() const { return _app.data.length == 0; }
	void pop() { _app.data[$ - 1].destroy(); _app.shrinkTo(_app.data.length - 1); }
	void push(T t) { _app.put(t); }
}

/// A range of contiguous physical blocks, where file data are stored.
/// See_Also:
///     $(LINK2 ext4.html#ExtentRange, ExtentRange)
struct Extent
{
	/// First physical file system block covered by this extent.
	ulong physicalBlockNum;

	/// First block within the file that this extent covers.
	uint logicalBlockNum;

	/// Number of file system blocks covered by this extent.
	ushort blockCount;

	/// true for extents that were read correctly, false for bad ones.
	bool ok;

	///
	void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
	{
		void putRange(ulong start)
		{
			formatValue(sink, start, fmt);
			if (blockCount > 1)
			{
				sink("..");
				formatValue(sink, start + blockCount - 1, fmt);
			}
		}

		sink("@");
		putRange(logicalBlockNum);
		if (!ok)
			sink("(bad)");
		else if (blockCount == 0)
			sink("(empty)");
		else
		{
			sink(":[");
			putRange(physicalBlockNum);
			sink("]");
		}
	}
}

unittest
{
	auto ext = Extent.init;
	assert(to!string(ext) == "@0(bad)");
	ext = Extent(0, 31337, 0, false);
	assert(to!string(ext) == "@31337(bad)");
	ext = Extent(0, 4140, 0, true);
	assert(to!string(ext) == "@4140(empty)");
	ext = Extent(123456789012345, 2345678, 1, true);
	assert(to!string(ext) == "@2345678:[123456789012345]");
	ext = Extent(987654321098765, 73313, 100, true);
	assert(to!string(ext) == "@73313..73412:[987654321098765..987654321098864]");
}

/// Range allowing lazy iteration over extents in the extent tree.
/// See_Also:
///     $(LINK2 ext4.html#Extent, Extent)
struct GenericExtentRange(Cache)
{
	/// Construct a range of extents for inode #inodeNum.
	private this(Cache cache, ulong blockNum, uint offset)
	{
		_cache = cache;
		pushNode(blockNum, offset);
		descendToLeaf();
	}

	~this()
	{
		while (!_treePath.empty)
			_treePath.pop();
	}

	/// Input range interface
	@property bool empty() const { return _treePath.empty; }

	/// ditto
	@property Extent front() const { return _current; }

	/// ditto
	void popFront()
	{
		while (!_treePath.empty)
		{
			if (headerIsOk() && ++_treePath.top.nodeIndex < _treePath.top.header.eh_entries)
				break;
			_treePath.pop();
		}
		descendToLeaf();
	}

	/// Returns: a list of blocks occupied by the extent tree itself
	@property const(ulong[]) treeBlockNums() pure nothrow const
	{
		return _treeBlockNums.data;
	}

	invariant
	{
		assert(_treePath.empty || !headerIsOk || (_treePath.top.header.eh_entries | _treePath.top.nodeIndex) == 0
		    || _treePath.top.nodeIndex < _treePath.top.header.eh_entries);
	}

private:
	bool headerIsOk() pure nothrow const
	{
		return !_treePath.empty
			&& _treePath.top.header.ok
			&& _treePath.top.header.eh_magic == EXT4_EXT_MAGIC;
	}

	void pushNode(ulong headerBlockNum, uint headerOffset)
	{
		auto header = _cache.requestStruct!ext4_extent_header(headerBlockNum, headerOffset);
		_treePath.push(Node(header, headerBlockNum, headerOffset + cast(uint) ext4_extent_header.sizeof, 0));
		_treeBlockNums.put(headerBlockNum);
	}

	// Set _current to the first extent of the leaf node, or a bad extent
	// if read error occured while descending.
	void descendToLeaf()
	{
		if (_current.ok)
			_current = Extent(0, _current.logicalBlockNum + _current.blockCount, 0, false);
		if (_treePath.empty || !headerIsOk)
			return;
		while (_treePath.top.header.eh_depth > 0)
		{
			Cache.Struct!ext4_extent_idx idx = _cache.requestStruct!ext4_extent_idx(
				_treePath.top.blockNum,
				_treePath.top.arrayOffset + _treePath.top.nodeIndex * ext4_extent_idx.sizeof);
			if (!idx.ok)
				return;
			_current.logicalBlockNum = idx.ei_block;
			ulong blockNum = bitCat(idx.ei_leaf_hi, idx.ei_leaf_lo);
			pushNode(blockNum, 0);
			if (!headerIsOk)
				return;
		}
		if (_treePath.top.header.eh_entries == 0)
		{
			_current = Extent(0, _current.logicalBlockNum + _current.blockCount, 0, true);
			return;
		}
		Cache.Struct!ext4_extent extent = _cache.requestStruct!ext4_extent(
			_treePath.top.blockNum,
			_treePath.top.arrayOffset + _treePath.top.nodeIndex * ext4_extent_idx.sizeof);
		if (!extent.ok)
			return;
		_current = Extent(extent.start, extent.logicalBlockNum, extent.len, true);
	}

	struct Node
	{
		Cache.Struct!ext4_extent_header header;
		ulong blockNum;   // physical block where the tree node is located
		uint arrayOffset; // where the array of ext4_extent starts within the block
		uint nodeIndex;   // current entry within this node
	}

	Extent _current = Extent(0, 0, 0, false);
	Cache _cache;
	Stack!Node _treePath;
	Appender!(ulong[]) _treeBlockNums;
}

///
alias ExtentRange = GenericExtentRange!BlockCache;

version(unittest)
{
	private struct TestCachedStruct(S)
	{
		const(ubyte[]) _payload;
		bool ok;
		@property const(S*) _s() pure nothrow const { return cast(const(S*)) _payload.ptr; }
		alias _s this;
	}

	private class TestCache
	{
		alias Struct = TestCachedStruct;

		ubyte[] _data;
		uint _blockSize;
		bool[ulong] _good;
		ulong _boffset;

		this(ulong blockCount, uint blockSize)
		{
			_data.length = blockCount * blockSize;
			_blockSize = blockSize;
		}

		Struct!S requestStruct(S)(ulong block, size_t offset)
		{
			ulong boffset = block * _blockSize + offset;
			assert(boffset in _good, text("Trying to read struct@", boffset, ". Only these are available: ", _good));
			return TestCachedStruct!S(_data[boffset .. boffset + S.sizeof], _good[boffset]);
		}

		void put(S)(S s, bool good = true)
		{
			_data[_boffset .. _boffset + S.sizeof] = (cast(ubyte*) &s)[0 .. S.sizeof];
			_good[_boffset] = good;
			_boffset += S.sizeof;
		}

		void put(S)(S s, ulong block, size_t offset, bool good = true)
		{
			_boffset = block * _blockSize + offset;
			put(s, good);
		}
	}
}

unittest
{
	// Test flat tree.
	auto cache = new TestCache(20, 1000);
	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 3, 10, 0, 0), 13, 60);
	cache.put(ext4_extent(0, 19, 0xdead, 0xc0ffee));
	cache.put(ext4_extent(21, 29, 0xc0de, 0xbadf00d), false);
	cache.put(ext4_extent(100, 1421, 0x1337, 0xcafebabe));
	auto range = GenericExtentRange!TestCache(cache, 13, 60); //, 11 * ext4_extent.sizeof);
	assert(!range.empty);
	assert(range.front.ok);
	assert(range.front.logicalBlockNum == 0);
	assert(range.front.blockCount == 19);
	assert(range.front.physicalBlockNum == 0xdead00c0ffee);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok);
	assert(range.front.logicalBlockNum == 19);
	range.popFront();
	assert(!range.empty);
	assert(range.front.ok);
	assert(range.front.logicalBlockNum == 100);
	assert(range.front.physicalBlockNum == 0x1337cafebabe);
	range.popFront();
	assert(range.empty);
	assert(range.treeBlockNums == [ 13 ]);
}

unittest
{
	// Test flat tree with unreadable header.
	auto cache = new TestCache(20, 1000);
	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 3, 10, 0, 0), 13, 60, false);
	auto range = GenericExtentRange!TestCache(cache, 13, 60); //, 11 * ext4_extent.sizeof);
	assert(!range.empty);
	assert(!range.front.ok);
	assert(range.front.logicalBlockNum == 0);
	// Test flat tree with readable, but invalid header.
	cache.put(ext4_extent_header(~EXT4_EXT_MAGIC, 3, 10, 0, 0), 13, 60, true);
	range = GenericExtentRange!TestCache(cache, 13, 60); //, 11 * ext4_extent.sizeof);
	assert(!range.empty);
	assert(!range.front.ok);
	assert(range.front.logicalBlockNum == 0);
	// Test flat tree with empty header.
	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 0, 4, 0, 0), 13, 60, true);
	range = GenericExtentRange!TestCache(cache, 13, 60); //, 11 * ext4_extent.sizeof);
	assert(!range.empty);
	assert(range.front.ok);
	assert(range.front.logicalBlockNum == 0);
	assert(range.front.blockCount == 0);
	assert(range.treeBlockNums == [ 13 ]);
}

unittest
{
	// Three-level tree with two bad headers, two bad index entries, and some bad extent entries.
	auto cache = new TestCache(20, 1000);
	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 3, 10, 2, 0), 13, 60);
	cache.put(ext4_extent_idx(0, 14, 0, 0));
	cache.put(ext4_extent_idx(100, 15, 0, 0));
	cache.put(ext4_extent_idx(200, 16, 0, 0));

	cache.put(ext4_extent_header.init, 14, 0); // this is the 1st bad header

	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 4, 10, 1, 0), 15, 0);
	cache.put(ext4_extent_idx(100, 17, 0, 0));
	cache.put(ext4_extent_idx.init, false); // this are the two bad index entries
	cache.put(ext4_extent_idx.init, false);
	cache.put(ext4_extent_idx(170, 18, 0, 0));

	cache.put(ext4_extent_header.init, 16, 0); // and this is the 2nd bad header

	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 5, 10, 0, 0), 17, 0);
	cache.put(ext4_extent.init, false);
	cache.put(ext4_extent(100, 10, 0xbeef, 0xdeadc0de));
	cache.put(ext4_extent.init, false);
	cache.put(ext4_extent.init, false);
	cache.put(ext4_extent(120, 31, 0xbabe, 0xcafed00d));

	cache.put(ext4_extent_header(EXT4_EXT_MAGIC, 3, 10, 0, 0), 18, 0);
	cache.put(ext4_extent.init, false);
	cache.put(ext4_extent.init, false);
	cache.put(ext4_extent.init, false);

	auto range = GenericExtentRange!TestCache(cache, 13, 60); //, 11 * ext4_extent.sizeof);
	assert(!range.empty);
	assert(!range.front.ok); // bad header @14
	assert(range.front.logicalBlockNum == 0);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @17,0
	assert(range.front.logicalBlockNum == 100);
	range.popFront();
	assert(!range.empty);
	assert(range.front.ok);
	assert(range.front.logicalBlockNum == 100);
	assert(range.front.blockCount == 10);
	assert(range.front.physicalBlockNum == 0xbeefdeadc0de);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @ 17,2
	assert(range.front.logicalBlockNum == 110);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @ 17,3
	assert(range.front.logicalBlockNum == 110);
	range.popFront();
	assert(!range.empty);
	assert(range.front.ok);
	assert(range.front.logicalBlockNum == 120);
	assert(range.front.blockCount == 31);
	assert(range.front.physicalBlockNum == 0xbabecafed00d);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad idx @15,1
	assert(range.front.logicalBlockNum == 151);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad idx @15,2
	assert(range.front.logicalBlockNum == 151);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @18,0
	assert(range.front.logicalBlockNum == 170);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @18,1
	assert(range.front.logicalBlockNum == 170);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad extent @18,2
	assert(range.front.logicalBlockNum == 170);
	range.popFront();
	assert(!range.empty);
	assert(!range.front.ok); // bad header @16
	assert(range.front.logicalBlockNum == 200);
	range.popFront();
	assert(range.empty);
	assert(range.treeBlockNums == [ 13, 14, 15, 17, 18, 16 ]);
}

struct DirIterator
{
	this(Ext4 ext4, uint inodeNum)
	{
		_cache = ext4._cache;
		_extentRange = ext4.inodes[inodeNum].extents;
		nextExtent();
		if (!empty)
			_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.physicalBlockNum, _offset);
	}

	@property bool empty() const pure nothrow
	{
		return _currentExtent.blockCount == 0;
	}

	@property auto front()
	{
		assert(!empty);
		return _current;
	}

	@property void popFront()
	{
		if (_current.ok)
		{
			_offset += front.rec_len;
			if (_offset < _cache.blockSize)
			{
				_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.physicalBlockNum, _offset);
				return;
			}
		}
		nextBlock();
	}

private:
	void nextBlock()
	{
		if (--_currentExtent.blockCount > 0)
			++_currentExtent.physicalBlockNum;
		else
			nextExtent();
		_offset = 0;
		_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.physicalBlockNum, _offset);
	}

	void nextExtent()
	{
		if (!_extentRange.empty)
		{
			_currentExtent = _extentRange.front;
			_extentRange.popFront();
		}
		else
		{
			_currentExtent.blockCount = 0;
		}
	}

	CachedStruct!ext4_dir_entry_2 _current;
	Extent _currentExtent;
	ExtentRange _extentRange;
	BlockCache _cache;
	uint _offset;
}

/// Provides access to ext4 file system structures.
class Ext4
{
	/** Open a file system.
	 *  Params:
	 *   fileName         = Name of the file containing the filesystem.
	 *   ddrescueLog      = Information about bad regions. If not provided, all the file system data are assumed good.
	 *   superBlockOffset = Offset of super block in the file system, in bytes.
	 *  See_Also:
	 *   $(LINK2 ddrescue.html, ddrescue)
	 */
	this(string fileName, const(Region)[] ddrescueLog = null, ulong superBlockOffset = 1024)
	{
		if (!ddrescueLog)
			ddrescueLog ~= Region(0, getFileSize(fileName), true);
		enum defaultBlockSize = 1024;
		_cache = new BlockCache(fileName, ddrescueLog, defaultBlockSize);
		scope(failure) destroy(_cache);
		auto superBlock = _cache.requestStruct!ext4_super_block(superBlockOffset);
		enforce(superBlock.ok, text("Super block at ", superBlockOffset, " is damaged"));
		enforce(superBlock.s_magic == 0xef53, text("Invalid super block at file offset ", superBlockOffset));
		uint blockSize = 1024 << superBlock.s_log_block_size;
		if (blockSize != _cache.blockSize)
		{
			debug writeln(blockSize, " != ", _cache.blockSize);
			destroy(superBlock);
			destroy(_cache);
			_cache = new BlockCache(fileName, ddrescueLog, blockSize);
			superBlock = _cache.requestStruct!ext4_super_block(superBlockOffset);
		}
		_superBlockIndex = superBlockOffset / _cache.blockSize;
		_superBlock = superBlock;
		_blockSize = blockSize;
		_inodesPerBlock = _blockSize / _superBlock.s_inode_size;
		enforce(_inodesPerBlock * _superBlock.s_inode_size == blockSize);
	}

	struct Inode
	{
		this(Ext4 ext4, uint inodeNum)
		{
			this.ext4 = ext4;
			this.inodeNum = inodeNum;
			this.inodeStruct = ext4.readInode(inodeNum);
		}

		/// Number of disk blocks (i.e. blocks of fixed size == 512B) allocated to this file,
		/// as reported in the inode.
		@property ulong blockCount()
		{
			if (!ext4._superBlock.s_feature_ro_compat_huge_file)
				return inodeStruct.i_blocks_lo;
			if (!inodeStruct.i_flags_huge_file)
				return bitCat(inodeStruct.l_i_blocks_high, inodeStruct.i_blocks_lo);
			// if huge_file flag is set in super block AND inode, block count is in filesystem blocks.
			return bitCat(inodeStruct.l_i_blocks_high, inodeStruct.i_blocks_lo) << (1 + ext4._superBlock.s_log_block_size);
		}

		@property bool isFastSymlink()
		{
			uint eaBlockCount = inodeStruct.i_file_acl_lo ? ext4.blockSize >> 9 : 0;
			return inodeStruct.mode.type == Mode.Type.symlink && this.blockCount - eaBlockCount == 0;
		}

		string getSymlinkTarget()
		{
			if (isFastSymlink)
			{
				enforce(inodeStruct.size <= inodeStruct.i_data.length, "Invalid file size");
				return inodeStruct.i_data[0 .. inodeStruct.size].idup;
			}
			else
			{
				enforce(inodeStruct.size <= ext4.blockSize, "Invalid file size");
				auto range = extents;
				if (range.empty || !range.front.ok)
					throw new Exception("Cannot read symlink target");
				auto block = ext4.cache.request(range.front.physicalBlockNum);
				return (cast(const(char[])) block[0 .. inodeStruct.size]).idup;
			}
		}

		DirIterator readAsDir()
		{
			return DirIterator(ext4, inodeNum);
		}

		@property ExtentRange extents()
		{
			auto loc = ext4.getInodeLocation(inodeNum);
			ulong blockNum = loc.blockNum;
			uint offset = loc.offset + cast(uint) (ext4_inode.i_block.offsetof);
			return ExtentRange(ext4._cache, blockNum, offset); //, cast(uint) ext4_inode.i_block.sizeof);
		}

		Ext4 ext4;
		uint inodeNum;
		CachedStruct!ext3_inode inodeStruct;

		alias inodeStruct this;
	}

	/** Access _inodes.
	 *  Examples:
	 *  --------------
	 *  auto ext4 = new Ext4(...);
	 *  writeln(ext4.inodes.length);               // number of inodes in the file system
	 *  writeln(ext4.inodes[10].ok);               // check whether the inode #10 was read correctly
	 *  writeln(typeof(ext4.inodes[1]).stringof);  // CachedStruct!(ext4_inode)
	 *  writefln("%o", ext4.inodes[2].i_mode);     // file mode for inode #2
	 *  foreach (inode; ext4.inodes[]) {}          // input range to iterate over all inodes
	 *  foreach (inode; ext4.inodes[1 .. 10]) {}   // input range to iterate over first 9 inodes
	 *  --------------
	 *  See_Also:
	 *   $(LINK2 blockcache.html#CachedStruct, CachedStruct)
	 *   $(LINK2 defs.html#ext4_inode, ext4_inode)
	 */
	@property auto inodes()
	{
		static struct Inodes
		{
			@property uint length() { return _ext4._superBlock.s_inodes_count; }

			auto opSlice() { return Range(_ext4); }

			auto opSlice(uint begin, uint end) { return Range(_ext4, begin, end); }

			auto opIndex(uint inodeNum) { return Inode(_ext4, inodeNum); }

			static struct Range
			{
				private Ext4 _ext4;
				uint _current;
				uint _end;

				this(Ext4 ext4, uint begin = 1, uint end = uint.max)
				{
					_ext4 = ext4;
					uint inodeCount = _ext4._superBlock.s_inodes_count;
					enforce(begin >= 1, "Invalid inode range begin");
					if (end == uint.max)
						end = inodeCount + 1;
					else
						enforce(end <= inodeCount + 1, "Invalid inode range end");
					enforce(begin <= end, "Invalid inode range");
					_end = end;
					_current = begin;
				}

				@property bool empty() const nothrow { return _current >= _end; }
				@property void popFront() nothrow { ++_current; }
				auto front() { return Inode(_ext4, _current); }
			}

		private:
			this(Ext4 ext4) { _ext4 = ext4; }

			Ext4 _ext4;
		}

		return Inodes(this);
	}

	///
	@property inout(BlockCache) cache() inout { return _cache; }

	/** The currently used super block.
	 *  See_Also:
	 *   $(LINK2 blockcache.html#CachedStruct, CachedStruct)
	 *   $(LINK2 defs.html#ext4_super_block, ext4_super_block)
	 */
	ref const(CachedStruct!ext4_super_block) superBlock() const { return _superBlock; }

	/// Size of a block in bytes.
	@property uint blockSize() const { return _blockSize; }

private:
	CachedStruct!ext3_group_desc readGroupDesc(ulong groupNum)
	{
		auto descSize = _superBlock.desc_size;
		auto groupDescsPerBlock = _blockSize / descSize;
		assert(groupDescsPerBlock * descSize == _blockSize);
		ulong blockNum = _superBlockIndex + 1 + groupNum / groupDescsPerBlock;
		ulong offset = groupNum % groupDescsPerBlock * descSize;
		return _cache.requestStruct!ext3_group_desc(blockNum, offset);
	}

	auto getInodeLocation(ulong inodeNum)
	{
		--inodeNum; // counting inodes starts at #1
		assert(inodeNum < _superBlock.s_inodes_count);
		ulong groupNum = inodeNum / _superBlock.s_inodes_per_group;
		auto groupDesc = readGroupDesc(groupNum);
		if (!groupDesc.ok)
			return Tuple!(ulong, "blockNum", uint, "offset")(0, 0);
		auto inodeIndexInGroup = inodeNum % _superBlock.s_inodes_per_group;
		ulong blockNum = groupDesc.bg_inode_table_lo + inodeIndexInGroup / _inodesPerBlock;
		uint offset = cast(uint) ((inodeIndexInGroup % _inodesPerBlock) * _superBlock.s_inode_size);
		return Tuple!(ulong, "blockNum", uint, "offset")(blockNum, offset);
	}

	CachedStruct!ext3_inode readInode(ulong inodeNum)
	{
		auto loc = getInodeLocation(inodeNum);
		if (!loc.blockNum)
			_cache.requestStruct!ext3_inode();
		return _cache.requestStruct!ext3_inode(loc.blockNum, loc.offset);
	}

	BlockCache _cache;
	CachedStruct!ext4_super_block _superBlock;
	ulong _superBlockIndex;
	uint _inodesPerBlock;
	uint _blockSize;
}

version(unittest)
{
	// libguestfs declarations
	struct guestfs_h {}

	extern(C) guestfs_h* guestfs_create();
	extern(C) void guestfs_close(guestfs_h* g);
	extern(C) int guestfs_add_drive(guestfs_h* g, const(char)* filename);
	extern(C) int guestfs_launch(guestfs_h* g);
	extern(C) int guestfs_mount(guestfs_h* g, const(char)* device, const(char)* mountpoint);
	extern(C) int guestfs_touch(guestfs_h* g, const(char)* path);
	extern(C) int guestfs_mkdir(guestfs_h* g, const(char)* path);
	extern(C) int guestfs_mkdir_mode(guestfs_h* g, const(char)* path, int mode);
	extern(C) int guestfs_mkdir_p(guestfs_h* g, const(char)* path);
	extern(C) int guestfs_umount(guestfs_h* g, const(char)* pathordevice);
	extern(C) int guestfs_umount_all(guestfs_h* g);
	extern(C) int guestfs_upload(guestfs_h* g, const(char)* filename, const(char)* remotefilename);
	extern(C) const(char)* guestfs_last_error(guestfs_h* g);

	pragma(lib, "guestfs");

	class GuestfsException : Exception
	{
		this(string msg = null, string file = __FILE__, ulong line = cast(ulong) __LINE__, Throwable next = null)
		{
			super(msg, file, line, next);
		}
	}

	class Guestfs
	{
		guestfs_h* g;

		this()
		{
			g = enforce(guestfs_create, "Failed to create handle");
		}

		~this()
		{
			finalize();
		}

		void finalize()
		{
			if (g)
			{
				guestfs_umount_all(g);
				guestfs_close(g);
				g = null;
			}
		}

		void opDispatch(string op, T...)(T args)
		{
			this.enforce(mixin("guestfs_" ~ op)(g, args) == 0);
		}

		T enforce(T)(T value, lazy const(char)[] msg = null, string file = __FILE__, ulong line =  cast(ulong) __LINE__)
		{
			if (!!value)
				return value;
			throw new GuestfsException(msg ? msg.idup : (g ? guestfs_last_error(g).toString() : ""), file, line);
		}
	}

	string toString(const(char)* str)
	{
		import core.stdc.string : strlen;
		return str[0 .. strlen(str)].idup;
	}

	import std.file : remove;
	import std.process : wait, spawnProcess, thisProcessID;
	import std.string : toStringz;

	string createTestFilesystem(uint sizeMB, uint blockSize, void delegate(Guestfs g) populate)
	{
		auto fileName = "/tmp/ext4rescue.test." ~ to!string(thisProcessID);
		scope(failure) remove(fileName);

		wait(spawnProcess([ "dd", "if=/dev/zero", text("of=", fileName), "bs=1M", text("count=", sizeMB) ]));
		wait(spawnProcess([ "mkfs.ext4", "-F", "-b", to!string(blockSize), fileName ]));

		auto g = new Guestfs();
		scope(exit) g.finalize();

		g.add_drive(fileName.toStringz());
		g.launch();

		g.mount("/dev/sda".ptr, "/".ptr);

		populate(g);

		return fileName;
	}
}

unittest
{
	auto fsname = createTestFilesystem(128, 4096, (Guestfs g) {
		g.mkdir("/foobar".ptr);
	});
	scope(exit) remove(fsname);
	Region[] regions;
	scope ext4 = new Ext4(fsname, regions);
	DirIterator di = ext4.inodes[2].readAsDir();
	assert(di.front.name == ".");
	assert(di.front.inode == 2);
	assert(di.front.file_type == ext4_dir_entry_2.Type.dir);
	di.popFront();
	assert(di.front.name == "..");
	assert(di.front.inode == 2);
	assert(di.front.file_type == ext4_dir_entry_2.Type.dir);
	di.popFront();
	assert(di.front.name == "lost+found");
	assert(di.front.file_type == ext4_dir_entry_2.Type.dir);
	di.popFront();
	assert(di.front.name == "foobar");
	assert(di.front.file_type == ext4_dir_entry_2.Type.dir);
	di.popFront();
	assert(di.empty);
}
