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

private ulong getFileSize(const(char)[] name)
{
	auto file = File(name.idup, "rb");
	file.seek(0, SEEK_END);
	return file.tell();
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
			@property ulong length() { return _ext4._superBlock.s_inodes_count; }

			auto opSlice() { return Range(_ext4); }

			auto opSlice(ulong begin, ulong end) { return Range(_ext4, begin, end); }

			auto opIndex(ulong inodeNum) { return _ext4.readInode(inodeNum); }

			static struct Range
			{
				private Ext4 _ext4;
				ulong _current;
				ulong _end;

				this(Ext4 ext4, ulong begin = 1, ulong end = ulong.max)
				{
					_ext4 = ext4;
					ulong inodeCount = _ext4._superBlock.s_inodes_count;
					enforce(begin >= 1, "Invalid inode range begin");
					if (end == ulong.max)
						end = inodeCount + 1;
					else
						enforce(end <= inodeCount + 1, "Invalid inode range end");
					enforce(begin <= end, "Invalid inode range");
					_end = end;
					_current = begin;
				}
			
				@property bool empty() const nothrow { return _current >= _end; }
				@property void popFront() nothrow { ++_current; }
				auto front() { return _ext4.readInode(_current); }
			}

		private:
			this(Ext4 ext4) { _ext4 = ext4; }

			Ext4 _ext4;
		}

		return Inodes(this);
	}

	static struct Stack(T)
	{
		import std.array: Appender, appender;
		Appender!(T[]) _app;
		@property ref inout(T) top() inout { return _app.data[$ - 1]; };
		@property bool empty() const { return _app.data.length == 0; }
		void pop() { _app.data[$ - 1].destroy(); _app.shrinkTo(_app.data.length - 1); }
		void push(T t) { _app.put(t); }
	}

	auto getExtentsForInode(ulong inodeNum)
	{
		static struct Extent
		{
			ulong start;
			uint length;
			uint logical;
			bool ok;

			string toString() const
			{
				import std.string;
				if (ok)
					return format("@%s..%s [%s..%s]", logical, logical + length - 1, start, start + length - 1);
				return "!ok";
			}
		}

		static struct Node
		{
			CachedStruct!ext4_extent_header header;
			ulong blockNum;   // physical block where the tree node is located
			uint arrayOffset; // where the array of ext4_extent starts within the block
			uint nodeIndex;   // current entry within this node
		}

		static struct Range
		{
		private:
			Extent _current;
			Stack!Node _treePath;
			Ext4 _ext4;
			bool _ok = true;

		public:
			/// Returns true if at least the root header is correct
			@property bool ok() const pure nothrow { return _ok; }

			this(Ext4 ext4, ulong inodeNum)
			{
				_ext4 = ext4;
				// root entries are inside the inode itself
				auto loc = _ext4.getInodeLocation(inodeNum);
				ulong blockNum = loc.blockNum;
				uint offset = loc.offset + cast(uint) (ext4_inode.i_block.offsetof);
				auto header = _ext4._cache.requestStruct!ext4_extent_header(blockNum, offset);
				if (!header.ok || header.eh_magic != EXT4_EXT_MAGIC)
				{
					_ok = false;
					return;
				}
				_treePath.push(Node(header, blockNum, offset + cast(uint) ext4_extent_header.sizeof, 0));
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
				_treePath.push(Node(header, headerBlockNum, headerOffset + cast(uint) ext4_extent_header.sizeof, 0));
			}

			private void descendToLeaf()
			{
				// read headers up to leaf level
				for (;;)
				{
					if (_treePath.top.header.eh_depth == 0)
					{
						// read leaf
						CachedStruct!ext4_extent ext = _ext4._cache.requestStruct!ext4_extent(
							_treePath.top.blockNum,
							_treePath.top.arrayOffset + _treePath.top.nodeIndex * ext4_extent_idx.sizeof);
						_current = Extent(bitCat(ext.ee_start_hi, ext.ee_start_lo), ext.ee_len, ext.ee_block, ext.ok);
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

			@property bool empty() const { return !_ok || _treePath.empty; }

			@property Extent front() const { return _current; }

			void popFront()
			{
				assert(!empty);
				while (!_treePath.empty)
				{
					if (++_treePath.top.nodeIndex < _treePath.top.header.eh_entries)
						break;
					_treePath.pop();
				}
				if (!_treePath.empty)
					descendToLeaf();
			}
		}

		return Range(this, inodeNum);
	}

	/** The currently used super block.
	 *  See_Also:
	 *   $(LINK2 blockcache.html#CachedStruct, CachedStruct)
	 *   $(LINK2 defs.html#ext4_super_block, ext4_super_block)
	 */
	ref const(CachedStruct!ext4_super_block) superBlock() const { return _superBlock; }

	/// Size of a block in bytes.
	@property uint blockSize() const { return _blockSize; }

private:
	CachedStruct!ext4_group_desc readGroupDesc(ulong groupNum)
	{
		auto descSize = _superBlock.desc_size;
		auto groupDescsPerBlock = _blockSize / descSize;
		assert(groupDescsPerBlock * descSize == _blockSize);
		ulong blockNum = _superBlockIndex + 1 + groupNum / groupDescsPerBlock;
		ulong offset = groupNum % groupDescsPerBlock * descSize;
		return _cache.requestStruct!ext4_group_desc(blockNum, offset);
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

	CachedStruct!ext4_inode readInode(ulong inodeNum)
	{
		auto loc = getInodeLocation(inodeNum);
		if (!loc.blockNum)
			_cache.requestStruct!ext4_inode();
		return _cache.requestStruct!ext4_inode(loc.blockNum, loc.offset);
	}

	BlockCache _cache;
	CachedStruct!ext4_super_block _superBlock;
	ulong _superBlockIndex;
	uint _inodesPerBlock;
	uint _blockSize;
}
