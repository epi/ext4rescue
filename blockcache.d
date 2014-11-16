/**
	Map ranges of the disk image file into memory. Automatically unmap
	ranges when they go out of scope. Cache some of the most recently used
	blocks for reuse. 

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
module blockcache;

import std.algorithm;
import std.conv;
import std.exception;
import std.range;
import std.stdint;
import std.string;

import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.sys.posix.sys.mman;

import ddrescue;

private enum PAGE_SHIFT = 12;
private enum PAGE_SIZE = cast(size_t) 1 << PAGE_SHIFT;
private enum PAGE_MASK = ~(PAGE_SIZE - 1);

private struct MemMappedExtentImpl
{
	// payload
	immutable(ubyte)* data;
	size_t size;

	bool ok;

	// ref counting
	uint refs = uint.max / 2;

	@property void* pagePtr() const pure nothrow
	{
		return cast(void*) (cast(intptr_t) data & PAGE_MASK);
	}

	@property size_t alignedSize() const pure nothrow
	{
		return ((cast(intptr_t) data & ~PAGE_MASK) + size + PAGE_SIZE - 1) & PAGE_MASK;
	}
}

/// A memory mapped extent (range of file system blocks).
/// Reference counting is used internally to manage lifetime of the mapping.
/// Mapping overlapping extents results in undefined behavior.
struct MemMappedExtent
{
	~this()
	{
		if (!_impl) return;
		assert(_impl.refs > 0 && _impl.refs != _impl.refs.init);
		--_impl.refs;
		if (!_impl.refs && _impl.data !is null)
		{
			munmap(_impl.pagePtr, _impl.alignedSize);
			clear(_impl);
		}
	}

	this(this)
	{
		if (!_impl) return;
		assert(_impl.refs && _impl.refs != _impl.refs.init);
		++_impl.refs;
	}

	void opAssign(MemMappedExtent rhs)
	{
		swap(_impl, rhs._impl);
	}

	ubyte opIndex(size_t i) const
	{
		assert(_impl);
		assert(i < length);
		return _impl.data[i];
	}

	immutable(ubyte)[] opSlice(size_t begin, size_t end) const
	{
		assert(_impl);
		assert(end <= length);
		assert(begin <= end);
		return _impl.data[begin .. end];
	}

	@property size_t length() const pure nothrow
	{
		assert(_impl);
		return _impl.size;
	}

	alias opDollar = length;

	immutable(ubyte)[] opSlice() const
	{
		return _impl.data[0 .. length];
	}

	@property bool ok() const pure nothrow
	{
		return _impl.ok;
	}

private:
	this(MemMappedExtentImpl* impl)
	{
		_impl = impl;
		++_impl.refs;
	}

	MemMappedExtentImpl* _impl;
}

private struct CachedPage
{
	// payload
	ulong pageNum;
	immutable(ubyte)* data;

	bool ok;

	// ref counting
	uint refs = uint.max / 2;

	// links to manage LRU list
	CachedPage* prev;
	CachedPage* next;
}

/// A memory mapped block.
/// The mapping is cached and reference counting is used internally to manage its lifetime.
/// In practice, this means that the block will not be unmapped until all references to it go out of scope
/// and the cache replacement policy selects it for eviction.
struct CachedBlock
{
	~this()
	{
		if (!_impl) return;
		assert(_impl.refs > 1 && _impl.refs != _impl.refs.init);
		--_impl.refs;
	}

	this(this)
	{
		if (!_impl) return;
		assert(_impl.refs && _impl.refs != _impl.refs.init);
		++_impl.refs;
	}

	void opAssign(CachedBlock rhs)
	{
		swap(_impl, rhs._impl);
	}

	ubyte opIndex(size_t i) const
	{
		return _impl.data[i + _offset];
	}

	immutable(ubyte)[] opSlice(size_t begin, size_t end) const
	{
		return _impl.data[_offset + begin .. _offset + end];
	}

	immutable(ubyte)[] opSlice() const
	{
		return _impl.data[_offset .. PAGE_SIZE];
	}

	@property bool ok() const pure nothrow
	{
		return _impl.ok;
	}

private:
	this(CachedPage* impl, uint offset = 0)
	{
		_impl = impl;
		++_impl.refs;
		_offset = offset;
	}
	
	CachedPage* _impl;
	uint _offset;
}

/// A struct view of a range within a block. Uses CachedBlock's logic for lifetime management and caching.
struct CachedStruct(S)
{
	alias _s this;

	@property bool ok() const pure nothrow { return _ok; }

private:
	@property immutable(S*) _s() const
	{
		with(_cachedBlock) return cast(immutable(S*)) _impl.data;
	}

	CachedBlock _cachedBlock;
	bool _ok;
}

/// Manages mapping of blocks and extents into memory. All mappings are read-only.
/// To make sure that all cached blocks are unmapped and the file is closed, invoke clear on a BlockCache instance.
class BlockCache
{
	/// Open the specified image file.
	/// Params:
	///  filename    = name of the image file.
	///  ddrescueLog = specification of damaged regions in the image, as obtained from ddrescue.parseLog().
	///  blockSize   = block size in bytes.
	///  capacity    = maximum number of cached blocks.
	/// See_Also:
	///  $(LINK2 ddrescue.html, ddrescue)
	this(string filename, const(Region[]) ddrescueLog, uint blockSize = PAGE_SIZE, uint capacity = 1048576)
	{
		assert(blockSize <= PAGE_SIZE);
		assert(PAGE_SIZE % blockSize == 0);
		_fd = open(filename.toStringz(), O_RDONLY);
		errnoEnforce(_fd >= 0, text("failed to open ", filename));
		_blocksPerPage = cast(uint) (PAGE_SIZE / blockSize);
		_freeSlots = capacity;
		_ddrescueLog = ddrescueLog;
	}

	~this()
	{
		CachedPage* cpage = _mru;
		while (cpage)
		{
			auto next = cpage.next;
			assert(cpage.refs == 1);
			unmap(cpage);
			// writefln("unmap %X", cpage.data);
			clear(*cpage);
			cpage = next;
		}
		_mru = null;
		_lru = null;
		if (_fd > 0)
		{
			close(_fd);
			_fd = -1;
		}
	}

	/// Map an extent starting at block blockNum with blockCount blocks.
	/// The extent is unmapped when all references go out of scope (i.e. extent mappings are NOT cached).
	/// Mapping overlapping extents results in undefined behavior.
	MemMappedExtent mapExtent(ulong blockNum, uint blockCount)
	{
		size_t blockSize = PAGE_SIZE / _blocksPerPage;
		size_t alignedSize = (blockNum % _blocksPerPage + blockCount + _blocksPerPage - 1) * blockSize & PAGE_MASK;
		ulong offset = blockNum * blockSize & PAGE_MASK;
		void* addr = mmap(null, alignedSize, PROT_READ, MAP_PRIVATE, _fd, offset);
		errnoEnforce(addr != MAP_FAILED, "mmap failed");
		auto mmei = new MemMappedExtentImpl;
		mmei.refs = 0;
		mmei.data = cast(immutable(ubyte)*) addr + (blockNum % _blocksPerPage) * blockSize;
		mmei.size = blockCount * blockSize;
		mmei.ok = _ddrescueLog.allGood(offset, offset + alignedSize);
		assert(mmei.pagePtr == addr);
		assert(mmei.alignedSize == alignedSize);
		return MemMappedExtent(mmei);
	}

	/// Map block blockNum. Reuse existing mapping if the block is already in cache.
	CachedBlock request(ulong blockNum)
	{
		ulong pageNum = blockNum / _blocksPerPage;
		auto centry = _hashTable.get(pageNum, null);
		if (centry)
		{
			moveToFront(centry);
		}
		else
		{
			if (_freeSlots)
				insert(pageNum);
			else
				replaceLru(pageNum);
			ulong offset = PAGE_SIZE * pageNum;
			_mru.data = cast(immutable(ubyte)*) mmap(null, PAGE_SIZE, PROT_READ, MAP_PRIVATE, _fd, offset);
			errnoEnforce(_mru.data != MAP_FAILED, "mmap failed");
			_mru.ok = _ddrescueLog.allGood(offset, offset + PAGE_SIZE);
		}
		return CachedBlock(_mru, blockNum % _blocksPerPage);
	}

	/// Map block blockNum and return a refcounted handle to access the part of the block at the given offset
	/// as struct S.
	CachedStruct!S requestStruct(S)(ulong blockNum, size_t offset)
	{
		auto cb = request(blockNum);
		ulong fileOffset = cb._impl.pageNum * PAGE_SIZE + offset;
		return CachedStruct!S(cb, _ddrescueLog.allGood(fileOffset, fileOffset + S.sizeof));
	}

private:
	void unmap(CachedPage* cpage)
	{
		errnoEnforce(munmap(cast(void*) cpage.data, PAGE_SIZE) == 0);
	}

	void moveToFront(CachedPage* cpage)
	{
		assert(cpage);
		assert(_mru);
		if (cpage == _mru)
			return;
		// remove from old location
		if (cpage.prev)
			cpage.prev.next = cpage.next;
		if (cpage.next)
			cpage.next.prev = cpage.prev;
		else
			_lru = cpage.prev;
		// insert as mru
		cpage.prev = null;
		cpage.next = _mru;
		_mru.prev = cpage;
		_mru = cpage;
	}
	
	void insert(ulong pageNum)
	{
		// writeln("insert ", pageNum, ", fs: ", _freeSlots);
		if (!_freeSlots)
			throw new Exception("Disk cache full");
	 	--_freeSlots;
		auto cpage = new CachedPage;
		cpage.refs = 1;
		cpage.pageNum = pageNum;
		cpage.next = _mru;
		cpage.prev = null;
		if (_mru)
			_mru.prev = cpage;
		_mru = cpage;
		if (!_lru)
			_lru = cpage;
		_hashTable[pageNum] = cpage;
	}

	// replaces the least recently used node that has
	// no references outside the cache (i.e. refs == 1)
	// with a new entry
	void replaceLru(ulong pageNum)
	{
		for (auto cpage = _lru; cpage !is null; cpage = cpage.prev)
		{
			if (cpage.refs == 1)
			{
				// remove
				unmap(cpage);
				_hashTable.remove(cpage.pageNum);
				// replace
				cpage.pageNum = pageNum;
				_hashTable[pageNum] = cpage;
				moveToFront(cpage);
				return;
			}
		}
		insert(pageNum);
	}

	int _fd = -1;
	uint _freeSlots = 1048576;
	CachedPage*[ulong] _hashTable;
	CachedPage* _mru;
	CachedPage* _lru;
	const(Region[]) _ddrescueLog;
	uint _blocksPerPage;
}

version (unittest)
{
	import std.conv;
	import std.exception;
	import std.file;
	import std.path;
	import std.process;
	import std.stdio;
	import core.thread;

	struct TempImage
	{
		string name;
		Region[] ddrescuelog;

		this(ulong size)
		{
			name = buildPath(tempDir(), "deleteme.ext4rescue.unittest.pid") ~ to!string(thisProcessID);
			auto f = File(name, "wb");
			enum blockSize = 4096;
			auto buf = new ubyte[blockSize];
			bool ok = true;
			foreach (bn; 0 .. size)
			{
				foreach (ref b; buf)
					b = bn & 0xff;
				f.rawWrite(buf);
				ddrescuelog ~= Region(bn * blockSize, blockSize, ok);
				ok = !ok;
			}
		}

		~this()
		{
			collectException(remove(name));
		}
	}
}

unittest
{
	auto img = TempImage(1337);
	auto bcache = new BlockCache(img.name, img.ddrescuelog, PAGE_SIZE, 100);
	scope(exit) clear(bcache);

	foreach (bn; 0 .. 1337)
	{
		CachedBlock b = bcache.request(bn);
		b = bcache.request(bn);
		assert(b.ok == !(bn & 1));
	}
}

unittest
{
	auto img = TempImage(11337);
	auto bcache = new BlockCache(img.name, img.ddrescuelog, 1024);
	scope(exit) clear(bcache);

	foreach (bn; 0 .. 1337)
	{
		foreach (bc; 9800 .. 10000)
		{
			MemMappedExtent mme = bcache.mapExtent(bn, bc);
			assert(mme._impl.refs == 1);
			{
				auto mme2 = mme;
				assert(mme2._impl == mme._impl);
				assert(mme._impl.refs == 2);
				assert(mme2.length == bc * 1024);
				assert((cast(intptr_t) mme2._impl.data & ~PAGE_MASK) == (bn & 3) * 1024);
				assert(mme2[0] == mme2[][0]);
				assert(mme2[0] == bn / 4 % 256);
			}
			assert(mme._impl.refs == 1);
			assert(!mme.ok); // any extent longer than 4096 bytes is bad in the test image
		}
	}
}

unittest
{
	auto img = TempImage(1000);
	{
		auto bcache = new BlockCache(img.name, img.ddrescuelog, 4096, 100);
		scope(exit) clear(bcache);
		CachedBlock[200] cbs;
		foreach_reverse (bn; 0 .. 100)
		{
			cbs[bn * 2] = bcache.request(bn);
			assert(cbs[bn * 2]._impl.refs == 2);
			cbs[bn * 2 + 1] = bcache.request(bn);
			assert(cbs[bn * 2 + 1]._impl.refs == 3);
		}
		assertThrown(bcache.request(100));
		assert(!std.file.readText("/proc/self/maps").find(img.name).empty);
	}
	assert(std.file.readText("/proc/self/maps").find(img.name).empty);
}

unittest
{
	struct Foo
	{
		ubyte[16] bar;
	}
	auto img = TempImage(0x800);
	auto log = img.ddrescuelog.dup;
	log[0x136].size -= 16;
	log[0x137].position -= 16;
	auto bcache = new BlockCache(img.name, log, 4096);
	scope(exit) clear(bcache);
	auto cs = bcache.requestStruct!Foo(0x136, 0xfe0);
	assert(cs.bar[0] == 0x36);
	assert(cs.ok);
	cs = bcache.requestStruct!Foo(0x136, 0xfe8);
	assert(cs.bar[0] == 0x36);
	assert(!cs.ok);
}