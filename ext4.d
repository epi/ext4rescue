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
	import std.array: Appender, appender;
	Appender!(T[]) _app;
	@property ref inout(T) top() inout { return _app.data[$ - 1]; };
	@property bool empty() const { return _app.data.length == 0; }
	void pop() { _app.data[$ - 1].destroy(); _app.shrinkTo(_app.data.length - 1); }
	void push(T t) { _app.put(t); }
}

struct ExtentRange
{
	/// Construct a range of extents for inode #inodeNum.
	this(Ext4 ext4, ulong inodeNum)
	{
		_ext4 = ext4;
		_inodeNum = inodeNum;
		// root entries are inside the inode itself
		auto loc = _ext4.getInodeLocation(inodeNum);
		ulong blockNum = loc.blockNum;
		uint offset = loc.offset + cast(uint) (ext4_inode.i_block.offsetof);
		appendNode(blockNum, offset);
		descendToLeaf();
	}

	~this()
	{
		while (!_treePath.empty)
			_treePath.pop();
	}

	private void appendNode(ulong headerBlockNum, uint headerOffset)
	{
		auto header = _ext4._cache.requestStruct!ext4_extent_header(headerBlockNum, headerOffset);
		if (!header.ok || header.eh_magic != EXT4_EXT_MAGIC)
		{
			_ok = false;
			return;
		}
		if (header.eh_entries == 0)
			return;
		_treePath.push(Node(header, headerBlockNum, headerOffset + cast(uint) ext4_extent_header.sizeof, 0));
	}

	private void descendToLeaf()
	{
		if (_treePath.empty)
			return;
		// read headers up to leaf level
		for (;;)
		{
			if (_treePath.top.header.eh_depth == 0)
			{
				// read leaf
				CachedStruct!ext4_extent ext = _ext4._cache.requestStruct!ext4_extent(
					_treePath.top.blockNum,
					_treePath.top.arrayOffset + _treePath.top.nodeIndex * ext4_extent_idx.sizeof);
				_current = Extent(ext.start, ext.len, ext.logicalBlockNum, ext.ok);
				break;
			}
			else
			{
				// read index
				CachedStruct!ext4_extent_idx idx = _ext4._cache.requestStruct!ext4_extent_idx(
					_treePath.top.blockNum,
					_treePath.top.arrayOffset + _treePath.top.nodeIndex * ext4_extent_idx.sizeof);
				if (!idx.ok)
				{
					_current = Extent(0, 0, 0, false);
					break;
				}
				auto blockNum = bitCat(idx._s.ei_leaf_hi, idx._s.ei_leaf_lo);
				appendNode(blockNum, 0);
			}
		}
	}

	/// Returns true if at least the root header is correct
	@property bool ok() const pure nothrow { return _ok; }

	/// Input range interface
	@property bool empty() const { return !_ok || _treePath.empty; }

	/// ditto
	@property Extent front() const { return _current; }

	invariant
	{
		assert(_treePath.empty || _treePath.top.nodeIndex < _treePath.top.header.eh_entries);
	}

	/// ditto
	void popFront()
	{
		assert(!empty);
		while (!_treePath.empty)
		{
			if (++_treePath.top.nodeIndex < _treePath.top.header.eh_entries)
				break;
			_treePath.pop();
		}
		descendToLeaf();
	}

private:
	struct Node
	{
		CachedStruct!ext4_extent_header header;
		ulong blockNum;   // physical block where the tree node is located
		uint arrayOffset; // where the array of ext4_extent starts within the block
		uint nodeIndex;   // current entry within this node
	}

	ulong _inodeNum;
	Extent _current;
	Stack!Node _treePath;
	Ext4 _ext4;
	bool _ok = true;
}

struct Extent
{
	ulong start;
	uint length;
	uint logical;
	bool ok;

	void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
	{
		if (!ok)
			sink("!ok");
		else if (length == 0)
			sink("empty");
		else
		{
			sink("@");
			formatValue(sink, logical, fmt);
			if (length > 1)
			{
				sink("..");
				formatValue(sink, logical + length - 1, fmt);
			}
			sink(" [");
			formatValue(sink, start, fmt);
			if (length > 1)
			{
				sink("..");
				formatValue(sink, start + length - 1, fmt);
			}
			sink("]");
		}
	}
}

struct DirIterator
{
	this(Ext4 ext4, uint inodeNum)
	{
		_cache = ext4._cache;
		_extentRange = ext4.inodes[inodeNum].extents;
		nextExtent();
		if (!empty)
			_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.start, _offset);
	}

	@property bool empty() const pure nothrow
	{
		return _currentExtent.length == 0;
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
				_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.start, _offset);
				return;
			}
		}
		nextBlock();
	}

private:
	void nextBlock()
	{
		if (--_currentExtent.length > 0)
			++_currentExtent.start;
		else
			nextExtent();
		_offset = 0;
		_current = _cache.requestStruct!ext4_dir_entry_2(_currentExtent.start, _offset);
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
			_currentExtent.length = 0;
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

		DirIterator readAsDir()
		{
			return DirIterator(ext4, inodeNum);
		}

		@property ExtentRange extents()
		{
			return ExtentRange(ext4, inodeNum);
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
